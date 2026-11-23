// The forward pass on the CPU: the reference implementation of the model.
//
// A chunk of tokens goes through the decoder's visits in plan order. The
// residual stream is a list of finished blocks plus the current block's
// partial sum; every sublayer reads an attention-weighted mix of them
// ("attention residuals"). Layers [loop_start, loop_end) run loop_passes
// times: each pass restarts from the stream as it was before the loop, and
// its inputs are mixed with messages from the previous pass's output through
// gated controllers. Attention has no rotary embedding: it uses learned
// relative-position logits, short convolutions on keys and values, a
// per-token sink logit and an output gate. Feed-forward is 128 routed
// experts (top 8) with NVFP4 weights.
//
// Values are FP32; they are rounded to BF16 where the reference rounds them
// (normalized inputs, projection outputs, cached keys and values).
#include "internal.hpp"

#include <algorithm>
#include <chrono>
#include <cstring>
#include <cfloat>
#include <numeric>

#include <arm_neon.h>
#include <sys/mman.h>

namespace inkling
{
  struct scratch
  {
    std::vector<float> partial;
    std::vector<std::vector<float>> blocks;
    std::vector<float> prelude_partial;
    size_t prelude_blocks{};
    std::vector<std::vector<float>> previous;
    std::array<std::vector<float>, 4> messages;
    std::array<std::vector<float>, 3> inputs;
    std::array<std::vector<float>, 3> normed;
    std::vector<float> q, kraw, vraw, k, v, r, gate, sink, table, attended, out;
    std::vector<float> ffn_in, ffn, router, experts_out;
    std::vector<int32_t> chosen;
    std::vector<float> chosen_w;
    std::vector<float> gu, act, down;
    std::vector<float> conv_dyn;
    std::vector<float> ctl_in, ctl_c, ctl_gain, ctl_forget;
    std::vector<float> hidden;
  };

  namespace
  {
    float sigmoid(float const x)
    {
      return 1.0f / (1.0f + std::exp(-x));
    }

    float softcap(float const x, float const cap)
    {
      return cap > 0 ? cap * std::tanh(x / cap) : x;
    }

    void round_all(float *x, size_t const n)
    {
      for(size_t i{}; i < n; ++i)
      {
        x[i] = round_bf16(x[i]);
      }
    }

    // y[t, r] = W[r, :] . x[t, :] for rows [r0, r1); W BF16 [rows, in].
    void rows_bf16(uint16_t const *w, int64_t const in, float const *x, int32_t const tokens, float *y,
                   int64_t const out_stride, int64_t const r0, int64_t const r1)
    {
      for(int64_t r{ r0 }; r < r1; ++r)
      {
        uint16_t const *row{ w + r * in };
        for(int32_t t0{}; t0 < tokens; t0 += 4)
        {
          int32_t const nt{ std::min(4, tokens - t0) };
          float32x4_t acc[4][2];
          for(int32_t k{}; k < 4; ++k)
          {
            acc[k][0] = vdupq_n_f32(0);
            acc[k][1] = vdupq_n_f32(0);
          }
          for(int64_t i{}; i < in; i += 8)
          {
            uint16x8_t const wv{ vld1q_u16(row + i) };
            float32x4_t const w0{ vreinterpretq_f32_u32(vshll_n_u16(vget_low_u16(wv), 16)) };
            float32x4_t const w1{ vreinterpretq_f32_u32(vshll_high_n_u16(wv, 16)) };
            for(int32_t k{}; k < nt; ++k)
            {
              float const *xp{ x + static_cast<int64_t>(t0 + k) * in + i };
              acc[k][0] = vfmaq_f32(acc[k][0], w0, vld1q_f32(xp));
              acc[k][1] = vfmaq_f32(acc[k][1], w1, vld1q_f32(xp + 4));
            }
          }
          for(int32_t k{}; k < nt; ++k)
          {
            y[static_cast<int64_t>(t0 + k) * out_stride + r] = vaddvq_f32(vaddq_f32(acc[k][0], acc[k][1]));
          }
        }
      }
    }

    void rows_f32(float const *w, int64_t const in, float const *x, int32_t const tokens, float *y,
                  int64_t const out_stride, int64_t const r0, int64_t const r1)
    {
      for(int64_t r{ r0 }; r < r1; ++r)
      {
        float const *row{ w + r * in };
        for(int32_t t{}; t < tokens; ++t)
        {
          float const *xp{ x + static_cast<int64_t>(t) * in };
          float32x4_t a0{ vdupq_n_f32(0) }, a1{ vdupq_n_f32(0) };
          int64_t i{};
          for(; i + 8 <= in; i += 8)
          {
            a0 = vfmaq_f32(a0, vld1q_f32(row + i), vld1q_f32(xp + i));
            a1 = vfmaq_f32(a1, vld1q_f32(row + i + 4), vld1q_f32(xp + i + 4));
          }
          float s{ vaddvq_f32(vaddq_f32(a0, a1)) };
          for(; i < in; ++i)
          {
            s += row[i] * xp[i];
          }
          y[static_cast<int64_t>(t) * out_stride + r] = s;
        }
      }
    }

    // y [tokens, out] = x [tokens, in] times W^T, W [out, in] BF16 or F32.
    void linear(model const &m, tensor const *w, float const *x, int32_t const tokens, float *y)
    {
      auto const out{ w->dim(0) };
      auto const in{ w->dim(1) };
      if(w->type == dtype::bf16 && in % 8 == 0)
      {
        auto const *data{ static_cast<uint16_t const *>(w->data) };
        int64_t const grain{ std::max<int64_t>(4, 32768 / in) };
        m.workers->run(out, grain, [&](int64_t a, int64_t b) { rows_bf16(data, in, x, tokens, y, out, a, b); });
        return;
      }
      auto const *data{ m.f32(w) };
      int64_t const grain{ std::max<int64_t>(4, 16384 / in) };
      m.workers->run(out, grain, [&](int64_t a, int64_t b) { rows_f32(data, in, x, tokens, y, out, a, b); });
    }

    void rmsnorm(float const *x, float const *w, int64_t const n, float const eps, float *out)
    {
      double ss{};
      for(int64_t i{}; i < n; ++i)
      {
        ss += static_cast<double>(x[i]) * x[i];
      }
      auto const inv{ static_cast<float>(1.0 / std::sqrt(ss / static_cast<double>(n) + eps)) };
      for(int64_t i{}; i < n; ++i)
      {
        out[i] = x[i] * inv * (w ? w[i] : 1.0f);
      }
    }

    // NVFP4 row (cols values) dot x.
    float dot_nvfp4(uint8_t const *packed, uint8_t const *scales, float const *x, int32_t const cols, float const *e4m3)
    {
      static int8_t const table_values[16]{ 0, 1, 2, 3, 4, 6, 8, 12, 0, -1, -2, -3, -4, -6, -8, -12 };
      int8x16_t const table{ vld1q_s8(table_values) };
      float32x4_t acc{ vdupq_n_f32(0) };
      for(int32_t b{}; b < cols / 16; ++b)
      {
        uint8x8_t const bytes{ vld1_u8(packed + b * 8) };
        uint8x8_t const lo{ vand_u8(bytes, vdup_n_u8(0x0f)) };
        uint8x8_t const hi{ vshr_n_u8(bytes, 4) };
        uint8x8x2_t const z{ vzip_u8(lo, hi) };
        uint8x16_t const idx{ vcombine_u8(z.val[0], z.val[1]) };
        int8x16_t const q{ vqtbl1q_s8(table, idx) };
        int16x8_t const q0{ vmovl_s8(vget_low_s8(q)) };
        int16x8_t const q1{ vmovl_s8(vget_high_s8(q)) };
        float const *xp{ x + b * 16 };
        float32x4_t s{ vmulq_f32(vcvtq_f32_s32(vmovl_s16(vget_low_s16(q0))), vld1q_f32(xp)) };
        s = vfmaq_f32(s, vcvtq_f32_s32(vmovl_s16(vget_high_s16(q0))), vld1q_f32(xp + 4));
        s = vfmaq_f32(s, vcvtq_f32_s32(vmovl_s16(vget_low_s16(q1))), vld1q_f32(xp + 8));
        s = vfmaq_f32(s, vcvtq_f32_s32(vmovl_s16(vget_high_s16(q1))), vld1q_f32(xp + 12));
        acc = vfmaq_n_f32(acc, s, e4m3[scales[b]] * 0.5f);
      }
      return vaddvq_f32(acc);
    }

    // MXFP8 row (cols E4M3 bytes) dot x. E4M3 widens exactly to FP16 by
    // moving its exponent and mantissa bits up (the bias difference, 2^8, is
    // applied with the block's power-of-two scale).
    float dot_mxfp8(uint8_t const *values, uint8_t const *scales, float const *x, int32_t const cols)
    {
      float32x4_t acc{ vdupq_n_f32(0) };
      for(int32_t b{}; b < cols / 32; ++b)
      {
        float32x4_t s{ vdupq_n_f32(0) };
        for(int32_t half{}; half < 2; ++half)
        {
          uint8x16_t const v{ vld1q_u8(values + b * 32 + half * 16) };
          for(int32_t part{}; part < 2; ++part)
          {
            uint16x8_t const wide{ part ? vmovl_high_u8(v) : vmovl_u8(vget_low_u8(v)) };
            uint16x8_t const bits{ vorrq_u16(vshlq_n_u16(vandq_u16(wide, vdupq_n_u16(0x7f)), 7),
                                             vshlq_n_u16(vandq_u16(wide, vdupq_n_u16(0x80)), 8)) };
            float16x8_t const h{ vreinterpretq_f16_u16(bits) };
            float const *xp{ x + b * 32 + half * 16 + part * 8 };
            s = vfmaq_f32(s, vcvt_f32_f16(vget_low_f16(h)), vld1q_f32(xp));
            s = vfmaq_f32(s, vcvt_high_f32_f16(h), vld1q_f32(xp + 4));
          }
        }
        acc = vfmaq_n_f32(acc, s, std::ldexp(256.0f, static_cast<int>(scales[b]) - 127));
      }
      return vaddvq_f32(acc);
    }

    // Nonnegative E4M3 rounding (nearest even), as the reference's kernels.
    float round_e4m3(float const x)
    {
      uint32_t const exponent{ (std::bit_cast<uint32_t>(x) >> 23) & 255u };
      float const spacing{ std::bit_cast<float>((std::max(exponent, 121u) - 3u) << 23) };
      return std::nearbyint(x / spacing) * spacing;
    }

    float round_e2m1(float const x)
    {
      float const m{ std::abs(x) };
      float q{ m > 0.25f ? 0.5f : 0.0f };
      if(m >= 0.75f)
      {
        q = 1.0f;
      }
      if(m > 1.25f)
      {
        q = 1.5f;
      }
      if(m >= 1.75f)
      {
        q = 2.0f;
      }
      if(m > 2.5f)
      {
        q = 3.0f;
      }
      if(m >= 3.5f)
      {
        q = 4.0f;
      }
      if(m > 5.0f)
      {
        q = 6.0f;
      }
      return x < 0.0f ? -q : q;
    }

    // NVFP4 activation quantization with 4-over-6 block scales: each block of
    // 16 uses the E4M3 scale (range 6 or 4) with the smaller absolute error.
    // Writes the inner values (E2M1 times the block's E4M3 scale) and returns
    // the row's absolute maximum: x is about inner * max / 1536.
    constexpr float max_product{ 1536.0f };

    float quantize_nvfp4(float const *x, int32_t const n, float *out)
    {
      float row_max{};
      for(int32_t i{}; i < n; ++i)
      {
        row_max = std::max(row_max, std::abs(x[i]));
      }
      if(row_max == 0.0f)
      {
        std::fill(out, out + n, 0.0f);
        return 0.0f;
      }
      float const normalizer{ std::min(max_product / row_max, FLT_MAX) };
      float const decoder{ 1.0f / normalizer };
      float const outer{ row_max * (1.0f / max_product) };
      for(int32_t b{}; b < n; b += 16)
      {
        float block_max{};
        for(int32_t i{}; i < 16; ++i)
        {
          block_max = std::max(block_max, std::abs(x[b + i]));
        }
        float const scale_a{ round_e4m3(std::min(block_max * (normalizer * (1.0f / 6.0f)), 448.0f)) };
        float const scale_b{ round_e4m3(std::min(block_max * (normalizer * 0.25f), 448.0f)) };
        float const inv_a{ std::min(1.0f / (scale_a * decoder), FLT_MAX) };
        float const inv_b{ std::min(1.0f / (scale_b * decoder), FLT_MAX) };
        float ca[16], cb[16];
        float ea{}, eb{};
        for(int32_t i{}; i < 16; ++i)
        {
          ca[i] = round_e2m1(x[b + i] * inv_a) * scale_a;
          cb[i] = round_e2m1(x[b + i] * inv_b) * scale_b;
          ea += std::abs(x[b + i] - ca[i] * outer);
          eb += std::abs(x[b + i] - cb[i] * outer);
        }
        float const *chosen{ eb < ea ? cb : ca };
        for(int32_t i{}; i < 16; ++i)
        {
          out[b + i] = chosen[i];
        }
      }
      return row_max;
    }

    // MXFP8 activation quantization: a power-of-two scale per 32 values
    // (rounded up), values rounded to E4M3.
    float quantize_mxfp8(float const *x, int32_t const n, float *out)
    {
      for(int32_t b{}; b < n; b += 32)
      {
        float block_max{};
        for(int32_t i{}; i < 32; ++i)
        {
          block_max = std::max(block_max, std::abs(x[b + i]));
        }
        float const raw{ block_max * (1.0f / 448.0f) };
        uint32_t const bits{ std::bit_cast<uint32_t>(raw) };
        int32_t exponent{ static_cast<int32_t>(bits >> 23) + ((bits & 0x7fffff) ? 1 : 0) };
        exponent = std::min(exponent, 254);
        constexpr float minimum{ 0x1p-127f };
        if(!(raw > minimum))
        {
          exponent = 0;
        }
        float const scale{ std::max(std::bit_cast<float>(static_cast<uint32_t>(exponent) << 23), minimum) };
        float const inverse{ exponent == 0 ? 0x1p127f : 1.0f / scale };
        for(int32_t i{}; i < 32; ++i)
        {
          float const v{ std::clamp(x[b + i] * inverse, -448.0f, 448.0f) };
          float const r{ round_e4m3(std::abs(v)) };
          out[b + i] = (v < 0 ? -r : r) * scale;
        }
      }
      return 0.0f;
    }

    float const *e4m3_table()
    {
      static auto const table{ [] {
        std::array<float, 256> t{};
        for(int i{}; i < 256; ++i)
        {
          t[static_cast<size_t>(i)] = e4m3_to_f32(static_cast<uint8_t>(i));
        }
        return t;
      }() };
      return table.data();
    }

    // Attention-weighted mix of residual sources at each token: keys are the
    // RMS-normalized sources, which are also the values.
    void mix(std::vector<float const *> const &sources, float const *query, int32_t const tokens, int64_t const h,
             float *out)
    {
      auto const nsrc{ sources.size() };
      float const scale{ 1.0f / std::sqrt(static_cast<float>(h)) };
      std::vector<float> inv(nsrc), score(nsrc);
      for(int32_t t{}; t < tokens; ++t)
      {
        float best{ -INFINITY };
        for(size_t s{}; s < nsrc; ++s)
        {
          float const *x{ sources[s] + t * h };
          double ss{}, dq{};
          for(int64_t i{}; i < h; ++i)
          {
            ss += static_cast<double>(x[i]) * x[i];
            dq += static_cast<double>(x[i]) * query[i];
          }
          inv[s] = static_cast<float>(1.0 / std::sqrt(ss / static_cast<double>(h) + 1e-6));
          score[s] = static_cast<float>(dq) * inv[s] * scale;
          best = std::max(best, score[s]);
        }
        float den{};
        for(size_t s{}; s < nsrc; ++s)
        {
          score[s] = std::exp(score[s] - best);
          den += score[s];
        }
        float *o{ out + t * h };
        std::fill(o, o + h, 0.0f);
        for(size_t s{}; s < nsrc; ++s)
        {
          float const wgt{ score[s] / den * inv[s] };
          float const *x{ sources[s] + t * h };
          for(int64_t i{}; i < h; ++i)
          {
            o[i] += wgt * x[i];
          }
        }
      }
    }

    void clip_l2(float *x, int64_t const n, float const *weight, float const threshold, float const tau)
    {
      double ss{};
      for(int64_t i{}; i < n; ++i)
      {
        if(weight)
        {
          x[i] *= weight[i];
        }
        ss += static_cast<double>(x[i]) * x[i];
      }
      float const norm{ static_cast<float>(std::sqrt(ss)) };
      float const factor{ std::min(threshold / (norm + 1e-6f), 1.0f) * tau };
      for(int64_t i{}; i < n; ++i)
      {
        x[i] *= factor;
      }
    }

    struct tracer
    {
      session &s;
      std::string prefix;

      void put(std::string const &name, float const *x, std::vector<int64_t> shape)
      {
        if(!s.trace)
        {
          return;
        }
        int64_t n{ 1 };
        for(auto const d : shape)
        {
          n *= d;
        }
        s.traces.push_back({ prefix + name, std::move(shape), std::vector<float>(x, x + n) });
      }
    };

    // A short causal convolution over the chunk, updating its history.
    void short_conv_apply(model const &m, short_conv const &c, float *x, int32_t const tokens, float *history,
                          float const *conditioning, scratch &w, std::vector<float> *const taps_out = nullptr,
                          float *const kept = nullptr)
    {
      int32_t const taps{ m.cfg.conv_taps };
      int32_t const tail{ taps - 1 };
      int64_t const ch{ c.channels };
      std::vector<float> window(static_cast<size_t>((tail + tokens) * ch));
      std::copy(history, history + tail * ch, window.begin());
      std::copy(x, x + tokens * ch, window.begin() + tail * ch);
      if(kept)
      {
        // A draft's check: the inputs, to roll back (truncate).
        std::copy(x, x + tokens * ch, kept);
      }
      if(c.weight_proj)
      {
        int32_t const heads{ c.heads };
        int64_t const per_head{ ch / heads };
        w.conv_dyn.resize(static_cast<size_t>(tokens * heads * taps));
        linear(m, c.weight_proj, conditioning, tokens, w.conv_dyn.data());
        round_all(w.conv_dyn.data(), w.conv_dyn.size());
        if(taps_out)
        {
          *taps_out = w.conv_dyn;
        }
        float const *stat{ m.f32(c.static_w) };
        float const norm{ 1.0f / std::sqrt(static_cast<float>(2 * taps + 1)) };
        for(int32_t t{}; t < tokens; ++t)
        {
          for(int64_t i{}; i < ch; ++i)
          {
            float sum{ window[static_cast<size_t>((t + tail) * ch + i)] };
            for(int32_t tap{}; tap < taps; ++tap)
            {
              float const coef{ stat[tap * ch + i] + w.conv_dyn[static_cast<size_t>((t * heads + i / per_head) * taps + tap)] };
              sum += coef * window[static_cast<size_t>((t + tail - tap) * ch + i)];
            }
            x[t * ch + i] = round_bf16(sum * norm);
          }
        }
      }
      else
      {
        float const *wt{ m.f32(c.weight) };
        float const norm{ 1.0f / std::sqrt(static_cast<float>(taps + 1)) };
        for(int32_t t{}; t < tokens; ++t)
        {
          for(int64_t i{}; i < ch; ++i)
          {
            float sum{ window[static_cast<size_t>((t + tail) * ch + i)] };
            for(int32_t tap{}; tap < taps; ++tap)
            {
              sum += wt[i * taps + tap] * window[static_cast<size_t>((t + tap) * ch + i)];
            }
            x[t * ch + i] = round_bf16(sum * norm);
          }
        }
      }
      std::copy(window.end() - tail * ch, window.end(), history);
    }

    // A loop controller: input * (1 - tanh(forget)) + message * tanh(gain).
    void controller(model const &m, message_gate const &g, float *input, float const *message, int32_t const tokens,
                    scratch &w, visit_capture *const cap, size_t const index)
    {
      int64_t const h{ m.cfg.hidden };
      int64_t const rank{ g.down->dim(0) };
      w.ctl_in.resize(static_cast<size_t>(tokens * 2 * h));
      for(int32_t t{}; t < tokens; ++t)
      {
        float *dst{ w.ctl_in.data() + t * 2 * h };
        rmsnorm(input + t * h, nullptr, h, 1e-6f, dst);
        rmsnorm(message + t * h, nullptr, h, 1e-6f, dst + h);
        round_all(dst, static_cast<size_t>(2 * h));
      }
      w.ctl_c.resize(static_cast<size_t>(tokens * rank));
      linear(m, g.down, w.ctl_in.data(), tokens, w.ctl_c.data());
      round_all(w.ctl_c.data(), w.ctl_c.size());
      if(cap)
      {
        cap->pairs[index] = w.ctl_in;
        cap->compressed[index] = w.ctl_c;
      }
      w.ctl_gain.resize(static_cast<size_t>(tokens * h));
      w.ctl_forget.resize(static_cast<size_t>(tokens * h));
      linear(m, g.gain, w.ctl_c.data(), tokens, w.ctl_gain.data());
      linear(m, g.forget, w.ctl_c.data(), tokens, w.ctl_forget.data());
      for(int64_t i{}; i < tokens * h; ++i)
      {
        auto const keep{ 1.0f - std::tanh(w.ctl_forget[static_cast<size_t>(i)]) };
        input[i] = input[i] * keep + message[i] * std::tanh(w.ctl_gain[static_cast<size_t>(i)]);
      }
    }

    void attention(session &s, int32_t const vi, layer_weights const &lw, int32_t const pos0, int32_t const tokens,
                   tracer &tr, visit_capture *const cap)
    {
      auto const &m{ *s.model };
      auto const &c{ m.cfg };
      auto &w{ *s.work };
      auto const &a{ lw.attn };
      auto &cache{ s.caches[static_cast<size_t>(vi)] };
      int64_t const h{ c.hidden };
      int32_t const heads{ a.heads };
      int32_t const kvh{ a.kv_heads };
      int32_t const hd{ a.head_dim };
      int32_t const rd{ c.rel_dim };
      int32_t const extent{ a.rel_extent };
      int64_t const qw{ heads * hd };
      int64_t const kw{ kvh * hd };
      float const *qn{ w.normed[0].data() };
      float const *kn{ w.normed[1].data() };
      float const *vn{ w.normed[2].data() };

      w.q.resize(static_cast<size_t>(tokens * qw));
      w.kraw.resize(static_cast<size_t>(tokens * kw));
      w.vraw.resize(static_cast<size_t>(tokens * kw));
      w.r.resize(static_cast<size_t>(tokens * heads * rd));
      w.gate.resize(static_cast<size_t>(tokens * qw));
      w.sink.resize(static_cast<size_t>(tokens * heads));
      linear(m, a.wq, qn, tokens, w.q.data());
      linear(m, a.wk, kn, tokens, w.kraw.data());
      linear(m, a.wv, vn, tokens, w.vraw.data());
      linear(m, a.wr, qn, tokens, w.r.data());
      linear(m, a.gate, qn, tokens, w.gate.data());
      linear(m, a.sink, qn, tokens, w.sink.data());
      round_all(w.q.data(), w.q.size());
      round_all(w.kraw.data(), w.kraw.size());
      round_all(w.vraw.data(), w.vraw.size());
      round_all(w.r.data(), w.r.size());
      round_all(w.gate.data(), w.gate.size());
      round_all(w.sink.data(), w.sink.size());
      if(cap)
      {
        cap->q_proj = w.q;
        cap->r_proj = w.r;
        cap->k_proj = w.kraw;
        cap->v_proj = w.vraw;
      }
      short_conv_apply(m, a.k_conv, w.kraw.data(), tokens, cache.conv[0], kn, w, cap ? &cap->k_taps : nullptr,
                       s.all_logits ? cache.kept[0] : nullptr);
      short_conv_apply(m, a.v_conv, w.vraw.data(), tokens, cache.conv[1], vn, w, cap ? &cap->v_taps : nullptr,
                       s.all_logits ? cache.kept[1] : nullptr);
      if(cap)
      {
        cap->k_conv = w.kraw;
        cap->v_conv = w.vraw;
      }

      float const *q_scale{ m.f32(a.q_scale) };
      float const *r_scale{ m.f32(a.r_scale) };
      float const *rel{ m.f32(a.rel_proj) };
      bool const global{ a.window == 0 };
      w.table.resize(static_cast<size_t>(tokens * heads * extent));
      for(int32_t t{}; t < tokens; ++t)
      {
        int32_t const p{ pos0 + t };
        float tau{ 1.0f };
        if(global && c.log_floor > 0 && c.log_alpha != 0)
        {
          tau = 1.0f + c.log_alpha * std::log(std::max(static_cast<float>(p + 1) / c.log_floor, 1.0f));
        }
        for(int32_t hh{}; hh < heads; ++hh)
        {
          clip_l2(w.q.data() + t * qw + hh * hd, hd, q_scale + hh * hd, c.qk_clip, tau);
          round_all(w.q.data() + t * qw + hh * hd, static_cast<size_t>(hd));
          float *rv{ w.r.data() + (t * heads + hh) * rd };
          clip_l2(rv, rd, r_scale + hh * rd, c.rel_clip, tau);
          round_all(rv, static_cast<size_t>(rd));
          float *tb{ w.table.data() + static_cast<int64_t>(t * heads + hh) * extent };
          for(int32_t d{}; d < extent; ++d)
          {
            float sum{};
            for(int32_t j{}; j < rd; ++j)
            {
              sum += rv[j] * rel[j * extent + d];
            }
            tb[d] = round_bf16(sum);
          }
        }
        auto const slot{ static_cast<size_t>(cache.slot(p)) };
        for(int32_t g{}; g < kvh; ++g)
        {
          float *kv{ w.kraw.data() + t * kw + g * hd };
          float *vv{ w.vraw.data() + t * kw + g * hd };
          clip_l2(kv, hd, nullptr, c.qk_clip, 1.0f);
          rmsnorm(vv, nullptr, hd, c.norm_eps, vv);
          for(int32_t i{}; i < hd; ++i)
          {
            cache.k[(slot * kvh + g) * hd + i] = f32_to_half(round_bf16(kv[i]));
            cache.v[(slot * kvh + g) * hd + i] = f32_to_half(round_bf16(vv[i]));
          }
        }
      }
      if(cap)
      {
        cap->q = w.q;
        cap->r = w.r;
        cap->sink = w.sink;
        cap->gate = w.gate;
        cap->k.resize(static_cast<size_t>(tokens * kw));
        cap->v.resize(static_cast<size_t>(tokens * kw));
        for(int32_t t{}; t < tokens; ++t)
        {
          auto const row{ static_cast<size_t>(cache.slot(pos0 + t)) * static_cast<size_t>(kw) };
          std::memcpy(cap->k.data() + t * kw, cache.k + row, static_cast<size_t>(kw) * 2);
          std::memcpy(cap->v.data() + t * kw, cache.v + row, static_cast<size_t>(kw) * 2);
        }
      }
      tr.put("attn.q", w.q.data() + (tokens - 1) * qw, { heads, hd });
      tr.put("attn.k", w.kraw.data() + (tokens - 1) * kw, { kvh, hd });
      tr.put("attn.v", w.vraw.data() + (tokens - 1) * kw, { kvh, hd });
      tr.put("attn.sink", w.sink.data() + (tokens - 1) * heads, { heads });

      // Scores, softmax with the sink logit, weighted values.
      w.attended.resize(static_cast<size_t>(tokens * qw));
      float const scale{ 1.0f / std::sqrt(static_cast<float>(hd)) };
      int32_t const group{ heads / kvh };
      int32_t const last_p{ pos0 + tokens - 1 };
      int32_t const last_first{ a.window > 0 ? std::max(0, last_p - a.window + 1) : 0 };
      std::vector<float> traced;
      if(s.trace)
      {
        traced.assign(static_cast<size_t>(heads) * (last_p - last_first + 1), 0.0f);
      }
      m.workers->run(static_cast<int64_t>(tokens) * heads, 1, [&](int64_t b, int64_t e) {
        std::vector<float> score;
        std::vector<float> acc(static_cast<size_t>(hd));
        for(int64_t item{ b }; item < e; ++item)
        {
          auto const t{ static_cast<int32_t>(item / heads) };
          auto const hh{ static_cast<int32_t>(item % heads) };
          int32_t const p{ pos0 + t };
          int32_t const first{ a.window > 0 ? std::max(0, p - a.window + 1) : 0 };
          int32_t const g{ hh / group };
          float const *qv{ w.q.data() + t * qw + hh * hd };
          float const *tb{ w.table.data() + static_cast<int64_t>(t * heads + hh) * extent };
          score.resize(static_cast<size_t>(p - first + 1));
          float best{ w.sink[static_cast<size_t>(t * heads + hh)] };
          for(int32_t j{ first }; j <= p; ++j)
          {
            auto const *kv{ reinterpret_cast<float16_t const *>(cache.k + (static_cast<size_t>(cache.slot(j)) * kvh + g) * hd) };
            float32x4_t d0{ vdupq_n_f32(0) }, d1{ vdupq_n_f32(0) };
            for(int32_t i{}; i < hd; i += 8)
            {
              float16x8_t const kb{ vld1q_f16(kv + i) };
              d0 = vfmaq_f32(d0, vcvt_f32_f16(vget_low_f16(kb)), vld1q_f32(qv + i));
              d1 = vfmaq_f32(d1, vcvt_high_f32_f16(kb), vld1q_f32(qv + i + 4));
            }
            int32_t const dist{ p - j };
            float sc{ vaddvq_f32(vaddq_f32(d0, d1)) * scale + (dist < extent ? tb[dist] : 0.0f) };
            score[static_cast<size_t>(j - first)] = sc;
            best = std::max(best, sc);
          }
          float den{ std::exp(w.sink[static_cast<size_t>(t * heads + hh)] - best) };
          for(auto &sc : score)
          {
            sc = std::exp(sc - best);
            den += sc;
          }
          std::fill(acc.begin(), acc.end(), 0.0f);
          for(int32_t j{ first }; j <= p; ++j)
          {
            float const pr{ score[static_cast<size_t>(j - first)] / den };
            uint16_t const *vv{ cache.v + (static_cast<size_t>(cache.slot(j)) * kvh + g) * hd };
            for(int32_t i{}; i < hd; ++i)
            {
              acc[static_cast<size_t>(i)] += pr * half_to_f32(vv[i]);
            }
            if(!traced.empty() && t == tokens - 1)
            {
              traced[static_cast<size_t>(hh) * (last_p - last_first + 1) + (j - first)] = pr;
            }
          }
          float *o{ w.attended.data() + t * qw + hh * hd };
          for(int32_t i{}; i < hd; ++i)
          {
            o[i] = acc[static_cast<size_t>(i)];
          }
        }
      });
      if(s.trace)
      {
        tr.put("attn.weights", traced.data(), { heads, last_p - last_first + 1 });
      }
      for(int64_t i{}; i < tokens * qw; ++i)
      {
        w.attended[static_cast<size_t>(i)] = round_bf16(w.attended[static_cast<size_t>(i)] * sigmoid(w.gate[static_cast<size_t>(i)]));
      }
      if(cap)
      {
        cap->attended = w.attended;
      }
      w.out.resize(static_cast<size_t>(tokens * h));
      linear(m, a.wo, w.attended.data(), tokens, w.out.data());
      round_all(w.out.data(), w.out.size());
      if(cap)
      {
        cap->attn_proj = w.out;
      }
    }

    void experts(session &s, layer_weights const &lw, float const *x, int32_t const tokens, float *out, tracer &tr,
                 visit_capture *const cap)
    {
      auto const &m{ *s.model };
      auto const &c{ m.cfg };
      auto &w{ *s.work };
      int64_t const h{ c.hidden };
      int32_t const ne{ c.experts };
      int32_t const k{ c.top_k };
      int32_t const width{ c.expert_width };
      w.router.resize(static_cast<size_t>(tokens * ne));
      linear(m, lw.router, x, tokens, w.router.data());
      float const *bias{ m.f32(lw.router_bias) };
      w.chosen.resize(static_cast<size_t>(tokens * k));
      w.chosen_w.resize(static_cast<size_t>(tokens * k));
      std::vector<int32_t> order(static_cast<size_t>(ne));
      std::vector<float> sel(static_cast<size_t>(ne));
      for(int32_t t{}; t < tokens; ++t)
      {
        float const *lg{ w.router.data() + t * ne };
        for(int32_t e{}; e < ne; ++e)
        {
          sel[static_cast<size_t>(e)] = sigmoid(lg[e]) + (bias ? bias[e] : 0.0f);
        }
        for(auto const e : m.banned_experts[static_cast<size_t>(lw.index)])
        {
          sel.at(static_cast<size_t>(e)) = -INFINITY;
        }
        std::iota(order.begin(), order.end(), 0);
        // By decreasing score; the lower index first among equals.
        std::partial_sort(order.begin(), order.begin() + k, order.end(), [&](int32_t a, int32_t b) {
          auto const x{ sel[static_cast<size_t>(a)] };
          auto const y{ sel[static_cast<size_t>(b)] };
          return x > y || (x == y && a < b);
        });
        float den{};
        for(int32_t j{}; j < k; ++j)
        {
          // softmax(log sigmoid(logit)) over the chosen ones.
          float const p{ sigmoid(lg[order[static_cast<size_t>(j)]]) };
          w.chosen[static_cast<size_t>(t * k + j)] = order[static_cast<size_t>(j)];
          w.chosen_w[static_cast<size_t>(t * k + j)] = p;
          den += p;
        }
        for(int32_t j{}; j < k; ++j)
        {
          w.chosen_w[static_cast<size_t>(t * k + j)] *= c.route_scale / den;
        }
      }
      if(s.trace)
      {
        tr.put("ffn.router", w.router.data() + (tokens - 1) * ne, { ne });
        std::vector<float> ids(static_cast<size_t>(k));
        for(int32_t j{}; j < k; ++j)
        {
          ids[static_cast<size_t>(j)] = static_cast<float>(w.chosen[static_cast<size_t>((tokens - 1) * k + j)]);
        }
        tr.put("ffn.experts", ids.data(), { k });
        tr.put("ffn.expert_weights", w.chosen_w.data() + (tokens - 1) * k, { k });
      }

      // Group the (token, slot) routes by expert.
      std::vector<std::vector<int32_t>> routes(static_cast<size_t>(ne));
      for(int32_t i{}; i < tokens * k; ++i)
      {
        routes[static_cast<size_t>(w.chosen[static_cast<size_t>(i)])].push_back(i);
      }
      std::vector<int32_t> active;
      for(int32_t e{}; e < ne; ++e)
      {
        if(!routes[static_cast<size_t>(e)].empty())
        {
          active.push_back(e);
        }
      }
      float const *e4m3{ e4m3_table() };
      auto const &gu{ lw.gate_up };
      auto const &dn{ lw.down };
      // Row `row` of expert `ex` of a bank, dot x.
      // Row `row` of expert `ex` of a bank, dot xv. For NVFP4 with quantized
      // inputs, xv holds inner values and xmax their row maximum.
      bool const quant{ m.quantize_expert_inputs };
      auto const row_dot{ [&](expert_bank const &bk, int32_t ex, int64_t row, float const *xv, float xmax) {
        auto const off{ static_cast<int64_t>(ex) * bk.rows + row };
        auto const *sc{ static_cast<uint8_t const *>(bk.scales->data) };
        auto const *wt{ static_cast<uint8_t const *>(bk.weight->data) };
        if(bk.nvfp4)
        {
          float const wmax{ m.f32(bk.amax)[ex] };
          float const den{ m.f32(bk.denominator)[0] };
          float const outer{ quant ? (xmax * wmax) / (den * max_product) : wmax / den };
          return dot_nvfp4(wt + off * (bk.cols / 2), sc + off * (bk.cols / 16), xv, bk.cols, e4m3) * outer;
        }
        return dot_mxfp8(wt + off * bk.cols, sc + off * (bk.cols / 32), xv, bk.cols);
      } };

      // The experts' inputs, quantized as the reference does.
      float const *xin{ x };
      std::vector<float> xq;
      std::vector<float> xmax(static_cast<size_t>(tokens), 0.0f);
      if(quant)
      {
        xq.resize(static_cast<size_t>(tokens * h));
        for(int32_t t{}; t < tokens; ++t)
        {
          xmax[static_cast<size_t>(t)]
            = (gu.nvfp4 ? quantize_nvfp4 : quantize_mxfp8)(x + t * h, static_cast<int32_t>(h), xq.data() + t * h);
        }
        xin = xq.data();
      }

      if(cap)
      {
        cap->router = w.router;
        cap->experts = w.chosen;
        cap->expert_weights = w.chosen_w;
        cap->expert_input.assign(xin, xin + tokens * h);
        cap->expert_input_max = xmax;
      }

      // Gate and up projections: rows 2i (gate) and 2i + 1 (up).
      int64_t const gu_rows{ gu.rows };
      w.gu.resize(static_cast<size_t>(tokens * k * gu_rows));
      auto const n_active{ static_cast<int64_t>(active.size()) };
      m.workers->run(n_active * gu_rows, 64, [&](int64_t b, int64_t e) {
        for(int64_t item{ b }; item < e; ++item)
        {
          int32_t const ex{ active[static_cast<size_t>(item / gu_rows)] };
          int64_t const row{ item % gu_rows };
          for(auto const route : routes[static_cast<size_t>(ex)])
          {
            w.gu[static_cast<size_t>(route * gu_rows + row)] = round_bf16(row_dot(gu, ex, row, xin + (route / k) * h, xmax[static_cast<size_t>(route / k)]));
          }
        }
      });
      w.act.resize(static_cast<size_t>(tokens * k * width));
      std::vector<float> amax(static_cast<size_t>(tokens * k), 0.0f);
      for(int32_t route{}; route < tokens * k; ++route)
      {
        float const *g{ w.gu.data() + route * gu_rows };
        float const weight{ w.chosen_w[static_cast<size_t>(route)] };
        float *a{ w.act.data() + route * width };
        for(int32_t i{}; i < width; ++i)
        {
          float const gate{ g[2 * i] };
          float const up{ g[2 * i + 1] };
          a[i] = round_bf16(softcap(gate, c.gate_cap) * sigmoid(gate) * softcap(up, c.up_cap) * weight);
        }
      }
      if(cap)
      {
        cap->activations_raw = w.act;
      }
      if(quant)
      {
        for(int32_t route{}; route < tokens * k; ++route)
        {
          float *a{ w.act.data() + route * width };
          amax[static_cast<size_t>(route)] = (dn.nvfp4 ? quantize_nvfp4 : quantize_mxfp8)(a, width, a);
        }
      }
      if(cap)
      {
        cap->activations = w.act;
        cap->activation_max = amax;
      }
      int64_t const dn_rows{ dn.rows };
      w.down.resize(static_cast<size_t>(tokens * k * dn_rows));
      m.workers->run(n_active * dn_rows, 64, [&](int64_t b, int64_t e) {
        for(int64_t item{ b }; item < e; ++item)
        {
          int32_t const ex{ active[static_cast<size_t>(item / dn_rows)] };
          int64_t const row{ item % dn_rows };
          for(auto const route : routes[static_cast<size_t>(ex)])
          {
            w.down[static_cast<size_t>(route * dn_rows + row)] = round_bf16(row_dot(dn, ex, row, w.act.data() + route * width, amax[static_cast<size_t>(route)]));
          }
        }
      });
      for(int32_t t{}; t < tokens; ++t)
      {
        float *o{ out + t * h };
        std::fill(o, o + h, 0.0f);
        for(int32_t j{}; j < k; ++j)
        {
          float const *d{ w.down.data() + (t * k + j) * dn_rows };
          for(int64_t i{}; i < h; ++i)
          {
            o[i] += d[i];
          }
        }
        round_all(o, static_cast<size_t>(h));
      }
      if(cap)
      {
        cap->ffn.assign(out, out + tokens * h);
        cap->ffn_routes = w.down;
      }
    }

    std::vector<float const *> stream_sources(scratch const &w)
    {
      std::vector<float const *> src;
      for(auto const &b : w.blocks)
      {
        src.push_back(b.data());
      }
      src.push_back(w.partial.data());
      return src;
    }
  }

  void cpu_linear(model const &m, tensor const *w, float const *x, int32_t const tokens, float *y)
  {
    linear(m, w, x, tokens, y);
  }

  void cpu_rmsnorm(float const *x, float const *w, int64_t const n, float const eps, float *out)
  {
    rmsnorm(x, w, n, eps, out);
  }

  void forward(session &s, int32_t const *ids, int32_t const tokens)
  {
    auto const &m{ *s.model };
    auto const &c{ m.cfg };
    auto &w{ *s.work };
    int64_t const h{ c.hidden };
    int32_t const pos0{ s.pos };
    auto const sz{ static_cast<size_t>(tokens * h) };
    s.traces.clear();

    // Embeddings, RMS-normalized.
    w.blocks.clear();
    w.partial.assign(sz, 0.0f);
    float const *embed_norm{ m.f32(m.embed_norm) };
    auto const *emb{ static_cast<uint16_t const *>(m.embed->data) };
    for(int32_t t{}; t < tokens; ++t)
    {
      float *row{ w.partial.data() + t * h };
      for(int64_t i{}; i < h; ++i)
      {
        row[i] = bf16_to_f32(emb[static_cast<int64_t>(ids[t]) * h + i]);
      }
      rmsnorm(row, embed_norm, h, c.norm_eps, row);
      round_all(row, static_cast<size_t>(h));
    }
    if(s.capturing)
    {
      s.captured = {};
      s.captured.tokens = tokens;
      s.captured.pos = pos0;
      s.captured.embed = w.partial;
      s.captured.visits.resize(m.plan.size());
    }
    tracer top{ s, "" };
    top.put("embed", w.partial.data() + (tokens - 1) * h, { h });

    for(auto &b : w.inputs)
    {
      b.resize(sz);
    }
    for(auto &b : w.normed)
    {
      b.resize(sz);
    }
    w.ffn_in.resize(sz);
    w.ffn.resize(sz);

    // A tap's row: BF16 bits of a hidden state, at position pos.
    size_t const ntaps{ s.tap_visits.size() + 1 };
    auto const tap{ [&](int32_t pos, size_t index, float const *x) {
      uint16_t *const out{ s.tap_ring + (static_cast<size_t>(pos % tap_slots) * ntaps + index) * static_cast<size_t>(h) };
      for(int64_t i{}; i < h; ++i)
      {
        uint32_t bits;
        std::memcpy(&bits, x + i, 4);
        out[i] = static_cast<uint16_t>(bits >> 16);
      }
    } };
    for(size_t vi{}; vi < m.plan.size(); ++vi)
    {
      auto const &visit{ m.plan[vi] };
      auto const &lw{ m.layers[static_cast<size_t>(visit.layer)] };
      tracer tr{ s, "v" + std::to_string(vi) + "." };
      bool const tapped_here{ s.tap_ring && std::find(s.tap_visits.begin(), s.tap_visits.end(), static_cast<int32_t>(vi)) != s.tap_visits.end() };
      bool const looped{ c.loop && visit.layer == c.loop_start };
      if(looped && visit.pass == 0)
      {
        w.prelude_blocks = w.blocks.size();
        w.prelude_partial = w.partial;
      }
      else if(looped)
      {
        // The previous pass's blocks (without the prelude's partial, pushed
        // at its first boundary) and its partial; then restart from the
        // prelude.
        w.previous.assign(w.blocks.begin() + static_cast<ptrdiff_t>(w.prelude_blocks) + 1, w.blocks.end());
        w.previous.push_back(w.partial);
        w.blocks.resize(w.prelude_blocks);
        w.partial = w.prelude_partial;
      }
      if(tapped_here)
      {
        // The partial sum entering this visit, for a draft model.
        auto const index{ static_cast<size_t>(std::find(s.tap_visits.begin(), s.tap_visits.end(), static_cast<int32_t>(vi))
                                              - s.tap_visits.begin()) };
        for(int32_t t{}; t < tokens; ++t)
        {
          tap(s.pos + t, index, w.partial.data() + static_cast<size_t>(t) * h);
        }
      }
      auto const off{ m.ablate[vi] };
      bool const with_messages{ visit.pass > 0 && !(off & no_messages) };
      if(with_messages)
      {
        std::vector<float const *> prev;
        for(auto const &p : w.previous)
        {
          prev.push_back(p.data());
        }
        for(int32_t i{}; i < 4; ++i)
        {
          w.messages[static_cast<size_t>(i)].resize(sz);
          mix(prev, lw.message_queries.data() + i * h, tokens, h, w.messages[static_cast<size_t>(i)].data());
        }
      }

      // Attention inputs.
      if(!w.blocks.empty() && lw.attn_query)
      {
        float const *qry{ m.f32(lw.attn_query) };
        auto const src{ stream_sources(w) };
        if(lw.attn_query->shape.size() == 1)
        {
          mix(src, qry, tokens, h, w.inputs[0].data());
          w.inputs[1] = w.inputs[0];
          w.inputs[2] = w.inputs[0];
        }
        else
        {
          for(int32_t i{}; i < 3; ++i)
          {
            mix(src, qry + i * h, tokens, h, w.inputs[static_cast<size_t>(i)].data());
          }
        }
      }
      else
      {
        for(auto &in : w.inputs)
        {
          in = w.partial;
        }
      }
      for(int32_t i{}; i < 3; ++i)
      {
        auto &in{ w.inputs[static_cast<size_t>(i)] };
        if(with_messages)
        {
          controller(m, lw.messages[static_cast<size_t>(i)], in.data(), w.messages[static_cast<size_t>(i)].data(), tokens, w,
                     s.capturing ? &s.captured.visits[vi] : nullptr, static_cast<size_t>(i));
        }
        float const *norm{ m.f32(lw.attn_norm[static_cast<size_t>(i)]) };
        for(int32_t t{}; t < tokens; ++t)
        {
          rmsnorm(in.data() + t * h, norm, h, c.norm_eps, w.normed[static_cast<size_t>(i)].data() + t * h);
        }
        round_all(w.normed[static_cast<size_t>(i)].data(), sz);
      }
      tr.put("attn.input", w.normed[0].data() + (tokens - 1) * h, { h });
      visit_capture *const cap{ s.capturing ? &s.captured.visits[vi] : nullptr };
      if(cap)
      {
        cap->inputs = w.normed;
      }

      attention(s, static_cast<int32_t>(vi), lw, pos0, tokens, tr, cap);
      auto &cache{ s.caches[vi] };
      short_conv_apply(m, lw.attn_conv, w.out.data(), tokens, cache.conv[2], nullptr, w, nullptr,
                       s.all_logits ? cache.kept[2] : nullptr);
      if(off & no_attention)
      {
        std::fill(w.out.begin(), w.out.end(), 0.0f);
      }
      tr.put("attn.out", w.out.data() + (tokens - 1) * h, { h });

      if(visit.layer % c.residual_block == 0)
      {
        w.blocks.push_back(w.partial);
        w.partial = w.out;
      }
      else
      {
        for(size_t i{}; i < sz; ++i)
        {
          w.partial[i] += w.out[i];
        }
      }

      if(cap)
      {
        cap->after_attention = w.partial;
      }

      // Feed-forward.
      mix(stream_sources(w), m.f32(lw.mlp_query), tokens, h, w.ffn_in.data());
      if(with_messages)
      {
        controller(m, lw.messages[3], w.ffn_in.data(), w.messages[3].data(), tokens, w, cap, 3);
      }
      float const *mlp_norm{ m.f32(lw.mlp_norm) };
      for(int32_t t{}; t < tokens; ++t)
      {
        rmsnorm(w.ffn_in.data() + t * h, mlp_norm, h, c.norm_eps, w.ffn_in.data() + t * h);
      }
      round_all(w.ffn_in.data(), sz);
      tr.put("ffn.input", w.ffn_in.data() + (tokens - 1) * h, { h });
      if(cap)
      {
        cap->ffn_input = w.ffn_in;
      }
      experts(s, lw, w.ffn_in.data(), tokens, w.ffn.data(), tr, cap);
      short_conv_apply(m, lw.mlp_conv, w.ffn.data(), tokens, cache.conv[3], nullptr, w, nullptr,
                       s.all_logits ? cache.kept[3] : nullptr);
      if(off & no_feed_forward)
      {
        std::fill(w.ffn.begin(), w.ffn.end(), 0.0f);
      }
      tr.put("ffn.out", w.ffn.data() + (tokens - 1) * h, { h });
      for(size_t i{}; i < sz; ++i)
      {
        w.partial[i] = round_bf16(w.partial[i] + w.ffn[i]);
      }
      tr.put("partial", w.partial.data() + (tokens - 1) * h, { h });
      if(cap)
      {
        cap->partial = w.partial;
        for(size_t i{}; i < 4; ++i)
        {
          cap->conv[i].assign(cache.conv[i], cache.conv[i] + static_cast<size_t>(c.conv_taps - 1) * cache.conv_width[i]);
        }
      }
    }

    // Output: mix, norm, unembed (FP32), softcap; for the last token, or for
    // every token with all_logits.
    w.hidden.resize(static_cast<size_t>(h));
    auto const normed{ [&](int32_t t) {
      std::vector<float const *> rows;
      for(auto const &b : w.blocks)
      {
        rows.push_back(b.data() + t * h);
      }
      rows.push_back(w.partial.data() + t * h);
      mix(rows, m.f32(m.out_query), 1, h, w.hidden.data());
      rmsnorm(w.hidden.data(), m.f32(m.out_norm), h, c.norm_eps, w.hidden.data());
      round_all(w.hidden.data(), static_cast<size_t>(h));
    } };
    if(s.tap_ring)
    {
      // Every token's final norm output, for a draft model.
      for(int32_t t{}; t < tokens; ++t)
      {
        normed(t);
        tap(s.pos + t, ntaps - 1, w.hidden.data());
      }
    }
    auto const output{ [&](int32_t t, float *logits) {
      normed(t);
      auto const *un{ static_cast<uint16_t const *>(m.unembed->data) };
      m.workers->run(c.unpadded_vocab, 512, [&](int64_t a, int64_t b) {
        rows_bf16(un, h, w.hidden.data(), 1, logits, c.unpadded_vocab, a, b);
      });
      for(int32_t i{}; i < c.unpadded_vocab; ++i)
      {
        logits[i] = softcap(logits[i], c.logit_cap);
      }
    } };
    if(s.all_logits)
    {
      size_t const v{ static_cast<size_t>(c.unpadded_vocab) };
      size_t const before{ s.row_logits.size() };
      s.row_logits.resize(before + static_cast<size_t>(tokens) * v);
      for(int32_t t{}; t < tokens; ++t)
      {
        output(t, s.row_logits.data() + before + static_cast<size_t>(t) * v);
      }
      s.logits.assign(s.row_logits.end() - static_cast<ptrdiff_t>(v), s.row_logits.end());
    }
    else
    {
      s.logits.resize(static_cast<size_t>(c.unpadded_vocab));
      output(tokens - 1, s.logits.data());
    }
    top.put("hidden", w.hidden.data(), { h });
    if(s.capturing)
    {
      s.captured.hidden = w.hidden;
      s.captured.logits = s.logits;
    }
    for(int32_t t{}; t < tokens; ++t)
    {
      s.tokens.push_back(ids[t]);
    }
    s.pos += tokens;
  }

  // Sessions.

  session::session() = default;

  session::~session()
  {
    metal_free_session(gpu);
    for(auto const &[p, bytes] : maps)
    {
      ::munmap(p, bytes);
    }
  }

  trace_entry const *session::find_trace(std::string_view const name) const
  {
    for(auto const &t : traces)
    {
      if(t.name == name)
      {
        return &t;
      }
    }
    return nullptr;
  }

  session *new_session(model &m, int32_t const context)
  {
    auto s{ std::make_unique<session>() };
    s->model = &m;
    s->context = context;
    s->work = std::make_unique<scratch>();
    auto const &c{ m.cfg };
    for(auto const &v : m.plan)
    {
      auto const &a{ m.layers[static_cast<size_t>(v.layer)].attn };
      visit_cache vc;
      vc.kv_heads = a.kv_heads;
      vc.head_dim = a.head_dim;
      vc.slots = a.window > 0 ? std::min(context, a.window + max_chunk) : context;
      vc.conv_width = { a.kv_heads * a.head_dim, a.kv_heads * a.head_dim, c.hidden, c.hidden };
      s->caches.push_back(vc);
    }
    if(m.gpu)
    {
      s->gpu = metal_new_session(*s);
      return s.release();
    }
    auto const map{ [&](size_t bytes) {
      void *p{ ::mmap(nullptr, bytes, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0) };
      if(p == MAP_FAILED)
      {
        fail("can't allocate a cache of " + std::to_string(bytes) + " bytes");
      }
      s->maps.emplace_back(p, bytes);
      return p;
    } };
    for(auto &vc : s->caches)
    {
      vc.k = static_cast<uint16_t *>(map(vc.kv_elements() * 2));
      vc.v = static_cast<uint16_t *>(map(vc.kv_elements() * 2));
      for(size_t i{}; i < 4; ++i)
      {
        vc.conv[i] = static_cast<float *>(map(static_cast<size_t>(c.conv_taps - 1) * vc.conv_width[i] * sizeof(float)));
        vc.kept[i] = static_cast<float *>(map(static_cast<size_t>(max_rows) * vc.conv_width[i] * sizeof(float)));
      }
    }
    return s.release();
  }

  void free_session(session *s)
  {
    delete s;
  }

  void reset(session &s)
  {
    s.pos = 0;
    s.tokens.clear();
    s.logits.clear();
    s.traces.clear();
    auto const tail{ static_cast<size_t>(s.model->cfg.conv_taps - 1) };
    for(auto &c : s.caches)
    {
      for(size_t i{}; i < 4; ++i)
      {
        std::memset(c.conv[i], 0, tail * c.conv_width[i] * sizeof(float));
      }
    }
  }

  void copy(session &dst, session const &src)
  {
    if(dst.model != src.model || dst.context != src.context)
    {
      fail("sessions of different models or contexts");
    }
    for(size_t i{}; i < src.caches.size(); ++i)
    {
      auto const &a{ src.caches[i] };
      auto &b{ dst.caches[i] };
      auto const rows{ std::min<size_t>(static_cast<size_t>(a.slots), static_cast<size_t>(src.pos)) };
      std::memcpy(b.k, a.k, rows * a.kv_heads * a.head_dim * 2);
      std::memcpy(b.v, a.v, rows * a.kv_heads * a.head_dim * 2);
      for(size_t j{}; j < 4; ++j)
      {
        std::memcpy(b.conv[j], a.conv[j], static_cast<size_t>(src.model->cfg.conv_taps - 1) * a.conv_width[j] * sizeof(float));
      }
    }
    dst.pos = src.pos;
    dst.tokens = src.tokens;
    dst.logits = src.logits;
    dst.traces = src.traces;
  }

  void eval(session &s, int32_t const *ids, size_t const n)
  {
    if(s.pos + static_cast<int64_t>(n) > s.context)
    {
      fail("the session's context (" + std::to_string(s.context) + " tokens) is full");
    }
    for(size_t i{}; i < n; ++i)
    {
      if(ids[i] < 0 || ids[i] >= s.model->cfg.vocab)
      {
        fail("token id " + std::to_string(ids[i]) + " is outside the vocabulary");
      }
    }
    if(s.all_logits && n > static_cast<size_t>(max_rows))
    {
      fail("an eval keeping every token's logits takes at most " + std::to_string(max_rows) + " tokens");
    }
    std::lock_guard<std::mutex> const one{ s.model->running };
    bool const gpu{ s.gpu && s.model->use_gpu && !s.trace && !s.model->ablated() };
    s.row_logits.clear();
    s.checked_from = -1;
    if(s.all_logits)
    {
      // What truncate goes back to: each convolution's history and the logits.
      size_t const tail{ static_cast<size_t>(s.model->cfg.conv_taps - 1) };
      for(auto &vc : s.caches)
      {
        for(size_t i{}; i < 4; ++i)
        {
          vc.before[i].assign(vc.conv[i], vc.conv[i] + tail * static_cast<size_t>(vc.conv_width[i]));
        }
      }
      s.logits_before = s.logits;
      s.checked_from = s.pos;
    }
    for(size_t i{}; i < n; i += max_chunk)
    {
      auto const len{ static_cast<int32_t>(std::min<size_t>(max_chunk, n - i)) };
      if(gpu)
      {
        metal_forward(s, ids + i, len);
      }
      else
      {
        forward(s, ids + i, len);
      }
    }
  }

  void eval(session &s, std::vector<int32_t> const &ids)
  {
    eval(s, ids.data(), ids.size());
  }

  std::vector<int32_t> context_draft(session const &s, int32_t const next, int32_t const least, int32_t const most)
  {
    // The sequence with `next`; its end matched against every earlier place, the
    // longest match (up to 64 tokens) kept, the latest among equals.
    std::vector<int32_t> const &t{ s.tokens };
    int64_t const n{ static_cast<int64_t>(t.size()) + 1 };
    auto const at{ [&](int64_t i) { return i == n - 1 ? next : t[static_cast<size_t>(i)]; } };
    if(least < 1 || most < 1 || n < least + 1)
    {
      return {};
    }
    int64_t best_end{ -1 };
    int64_t best_len{};
    // An earlier place `e` (the last token of a match) is a candidate when its
    // token equals the end's; the match is measured backwards from there.
    for(int64_t e{ n - 2 }; e >= least - 1 && best_len < 64; --e)
    {
      if(at(e) != next)
      {
        continue;
      }
      int64_t len{};
      while(len < 64 && e - len >= 0 && at(e - len) == at(n - 1 - len))
      {
        ++len;
      }
      if(len > best_len)
      {
        best_len = len;
        best_end = e;
      }
    }
    if(best_len < least)
    {
      return {};
    }
    std::vector<int32_t> draft;
    for(int64_t i{ best_end + 1 }; i < n - 1 && static_cast<int32_t>(draft.size()) < most; ++i)
    {
      draft.push_back(at(i));
    }
    return draft;
  }

  std::vector<int32_t> speculate(session &s, float const temperature, float const top_p, int32_t const top_k,
                                 uint64_t const seed, int32_t const limit, int32_t const least, int32_t const most,
                                 drafter *const d)
  {
    if(limit < 1)
    {
      fail("speculate: the limit is at least one token");
    }
    auto const v{ static_cast<int32_t>(s.model->cfg.unpadded_vocab) };
    auto const sampled{ [&](float const *logits, int32_t i) {
      uint64_t rng{ (seed + static_cast<uint64_t>(i)) | 1u };
      return sample(logits, v, temperature, top_p, top_k, rng);
    } };
    auto const started{ std::chrono::steady_clock::now() };
    int32_t const first{ sampled(s.logits.data(), 0) };
    int32_t const room{ std::min({ limit - 1, most, max_rows - 1, s.context - s.pos - 1 }) };
    std::vector<int32_t> rows{ first };
    // The draft model's checks (not the copies) tell its depth control.
    bool modelled{};
    if(room > 0)
    {
      auto proposed{ context_draft(s, first, least, room) };
      if(proposed.empty() && d)
      {
        int32_t const depth{ std::min(room, choose_depth(*d)) };
        modelled = true;
        if(depth > 0)
        {
          proposed = draft(*d, s, first, depth);
        }
      }
      rows.insert(rows.end(), proposed.begin(), proposed.end());
    }
    auto const told{ [&](size_t kept) {
      if(modelled)
      {
        double const ms{ std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - started).count() };
        observe_check(*d, static_cast<int32_t>(rows.size()) - 1, static_cast<int32_t>(kept) - 1, ms);
      }
    } };
    if(rows.size() == 1)
    {
      eval(s, rows);
      told(1);
      return rows;
    }
    bool const was{ s.all_logits };
    s.all_logits = true;
    eval(s, rows);
    s.all_logits = was;
    // Drafts kept while each equals what is sampled at its place.
    size_t kept{ 1 };
    while(kept < rows.size()
          && sampled(s.row_logits.data() + (kept - 1) * static_cast<size_t>(v), static_cast<int32_t>(kept)) == rows[kept])
    {
      ++kept;
    }
    if(kept < rows.size())
    {
      truncate(s, s.checked_from + static_cast<int32_t>(kept));
    }
    else
    {
      s.checked_from = -1;
    }
    told(kept);
    rows.resize(kept);
    return rows;
  }

  void keep_taps(session &s, std::vector<int32_t> const &visits)
  {
    for(auto const v : visits)
    {
      if(v < 0 || v >= static_cast<int32_t>(s.model->plan.size()))
      {
        fail("keep_taps: no visit " + std::to_string(v));
      }
    }
    std::lock_guard<std::mutex> const one{ s.model->running };
    s.tap_visits = visits;
    size_t const n{ static_cast<size_t>(tap_slots) * (visits.size() + 1) * static_cast<size_t>(s.model->cfg.hidden) };
    if(s.gpu)
    {
      s.tap_ring = metal_tap_ring(s, n);
    }
    else
    {
      s.tap_storage.assign(n, 0);
      s.tap_ring = s.tap_storage.data();
    }
  }

  void truncate(session &s, int32_t const pos)
  {
    if(s.checked_from < 0 || pos < s.checked_from || pos > s.pos)
    {
      fail("truncate goes back only within the last eval with all_logits (a draft's check)");
    }
    std::lock_guard<std::mutex> const one{ s.model->running };
    int32_t const k{ pos - s.checked_from };
    int32_t const tail{ s.model->cfg.conv_taps - 1 };
    // A convolution's history after k of the check's tokens: rows k .. k + tail
    // of (its history before the check ++ the check's inputs).
    for(auto &vc : s.caches)
    {
      for(size_t i{}; i < 4; ++i)
      {
        size_t const width{ static_cast<size_t>(vc.conv_width[i]) };
        for(int32_t r{}; r < tail; ++r)
        {
          int32_t const row{ k + r };
          float const *src{ row < tail ? vc.before[i].data() + static_cast<size_t>(row) * width
                                       : vc.kept[i] + static_cast<size_t>(row - tail) * width };
          std::copy(src, src + width, vc.conv[i] + static_cast<size_t>(r) * width);
        }
      }
    }
    // The keys and values after pos are left: they are written again before any
    // token reads them (a window's ring has max_chunk slots more than it reads).
    size_t const v{ static_cast<size_t>(s.model->cfg.unpadded_vocab) };
    if(k > 0)
    {
      s.logits.assign(s.row_logits.begin() + static_cast<ptrdiff_t>((k - 1) * v),
                      s.row_logits.begin() + static_cast<ptrdiff_t>(k * v));
    }
    else
    {
      s.logits = s.logits_before;
    }
    s.row_logits.resize(static_cast<size_t>(k) * v);
    s.tokens.resize(static_cast<size_t>(pos));
    s.pos = pos;
    s.checked_from = -1;
  }

  int32_t sample(float const *logits, int32_t const n, float const temperature, float const top_p, int32_t const top_k,
                 uint64_t &rng)
  {
    if(n <= 0)
    {
      fail("no logits to sample from: evaluate tokens first");
    }
    if(temperature <= 0)
    {
      return static_cast<int32_t>(std::max_element(logits, logits + n) - logits);
    }
    // xorshift64*: one number in [0, 1).
    rng ^= rng >> 12;
    rng ^= rng << 25;
    rng ^= rng >> 27;
    double const r{ static_cast<double>((rng * 2685821657736338717ull) >> 11) / 9007199254740992.0 };
    double const best{ *std::max_element(logits, logits + n) };
    auto const weight{ [&](int32_t i) { return std::exp((logits[i] - best) / temperature); } };
    bool const nucleus{ top_p > 0 && top_p < 1 };
    int32_t const k{ top_k > 0 ? std::min(top_k, n) : n };
    if(k == n && !nucleus)
    {
      // Every token: no order needed, the tokens in their own order.
      double total{};
      for(int32_t i{}; i < n; ++i)
      {
        total += weight(i);
      }
      double const u{ r * total };
      double acc{};
      for(int32_t i{}; i < n; ++i)
      {
        acc += weight(i);
        if(u < acc)
        {
          return i;
        }
      }
      return n - 1;
    }
    // The k most likely (ties by index), sorted only as far as needed: the top-p
    // cut is found among the first m, m growing until it is or m reaches k.
    std::vector<int32_t> idx(static_cast<size_t>(n));
    std::iota(idx.begin(), idx.end(), 0);
    auto const before{ [&](int32_t a, int32_t b) { return logits[a] > logits[b] || (logits[a] == logits[b] && a < b); } };
    if(k < n)
    {
      std::nth_element(idx.begin(), idx.begin() + k, idx.end(), before);
      idx.resize(static_cast<size_t>(k));
    }
    double sum{};
    for(auto const i : idx)
    {
      sum += weight(i);
    }
    int32_t keep{ k };
    double kept{ sum };
    int32_t m{ std::min(k, 64) };
    while(true)
    {
      std::partial_sort(idx.begin(), idx.begin() + m, idx.end(), before);
      if(!nucleus)
      {
        if(m == k)
        {
          break;
        }
        m = k;
        continue;
      }
      double acc{};
      int32_t found{ -1 };
      for(int32_t i{}; i < m; ++i)
      {
        acc += weight(idx[static_cast<size_t>(i)]);
        if(acc / sum >= top_p)
        {
          found = i;
          break;
        }
      }
      if(found >= 0)
      {
        keep = found + 1;
        kept = acc;
        break;
      }
      if(m == k)
      {
        break;
      }
      m = std::min(k, m * 4);
    }
    double const u{ r * kept };
    double acc{};
    for(int32_t i{}; i < keep; ++i)
    {
      acc += weight(idx[static_cast<size_t>(i)]);
      if(u < acc)
      {
        return idx[static_cast<size_t>(i)];
      }
    }
    return idx[static_cast<size_t>(keep - 1)];
  }
}

// check_gpu: the Metal path against the CPU reference, stage by stage.
//
// A chunk is evaluated on the CPU with capturing on. The GPU then evaluates
// the same chunk from the same state, and after each stage of each visit its
// values are captured and then overwritten with the CPU's (metal_forward's
// `force`). So every GPU stage is compared on the CPU's exact inputs:
// differences can't build up over the visits or flip a later routing choice.
//
// Tolerances, per value:
//  - values both paths round to BF16 (and sums of them): a BF16 unit in the
//    last place of the larger of the two, plus 2e-5 of the largest magnitude
//    in the field for the FP32 summation order;
//  - attention's output: the same with 1e-4, its sums running over every key
//    and through exp;
//  - the experts' activations: two units, the gate and up projections being
//    rounded before the nonlinearity that the activation is rounded after;
//  - the feed-forward sum: one unit per route as well, each route's part
//    being rounded before the sum;
//  - quantized values and maxima (the experts' inputs and activations): equal,
//    since the quantizers get identical inputs and do the same operations;
//  - the chosen experts: equal, unless the scores that decide are closer
//    than 1e-4 (the router's logits differ by summation order).
#include "internal.hpp"

#include <algorithm>

namespace inkling
{
  namespace
  {
    float bf16_ulp(float const x)
    {
      float const a{ std::abs(x) };
      if(a == 0.0f || !std::isfinite(a))
      {
        return 0.0f;
      }
      int e{};
      std::frexp(a, &e); // a = f * 2^e, f in [0.5, 1)
      return std::ldexp(1.0f, e - 8);
    }

    struct comparer
    {
      check_report &report;
      int32_t visit{};
      // The tolerance of the next comparisons: BF16 units of the value, and
      // a fraction of the field's largest magnitude.
      double units{ 1.0 };
      double floor{ 2e-5 };

      // mode 0: BF16 unit + 2e-5 of the field's scale; 1: exact. `slack`
      // adds a bound per value (the feed-forward sum's routes).
      void floats(char const *name, float const *a, float const *b, size_t na, size_t nb, int mode,
                  std::vector<bool> const *skip_rows = nullptr, size_t row = 0, std::vector<float> const *slack = nullptr)
      {
        check_row r{ visit, name };
        if(na != nb)
        {
          r.count = static_cast<int64_t>(std::max(na, nb));
          r.beyond = r.count;
          r.worst = INFINITY;
          add(r);
          return;
        }
        float scale{};
        for(size_t i{}; i < na; ++i)
        {
          scale = std::max(scale, std::abs(a[i]));
        }
        for(size_t i{}; i < na; ++i)
        {
          if(skip_rows && (*skip_rows)[i / row])
          {
            continue;
          }
          ++r.count;
          if(std::bit_cast<uint32_t>(a[i]) == std::bit_cast<uint32_t>(b[i]))
          {
            continue;
          }
          if(a[i] == b[i])
          {
            continue; // +0 and -0
          }
          ++r.different;
          double const diff{ std::abs(static_cast<double>(a[i]) - b[i]) };
          double const bound{ mode == 1 ? 0.0
                                        : units * bf16_ulp(std::max(std::abs(a[i]), std::abs(b[i]))) + floor * scale
                                            + (slack ? (*slack)[i] : 0.0f) };
          double const ratio{ bound > 0 ? diff / bound : INFINITY };
          r.worst = std::max(r.worst, ratio);
          if(!(ratio <= 1.0))
          {
            ++r.beyond;
          }
        }
        add(r);
      }

      void floats(char const *name, std::vector<float> const &a, std::vector<float> const &b, int mode,
                  std::vector<bool> const *skip_rows = nullptr, size_t row = 0, std::vector<float> const *slack = nullptr)
      {
        floats(name, a.data(), b.data(), a.size(), b.size(), mode, skip_rows, row, slack);
      }

      void halves(char const *name, std::vector<uint16_t> const &a, std::vector<uint16_t> const &b)
      {
        std::vector<float> fa(a.size()), fb(b.size());
        for(size_t i{}; i < a.size(); ++i)
        {
          fa[i] = half_to_f32(a[i]);
        }
        for(size_t i{}; i < b.size(); ++i)
        {
          fb[i] = half_to_f32(b[i]);
        }
        floats(name, fa, fb, 0);
      }

      void add(check_row const &r)
      {
        report.compared += r.count;
        report.beyond += r.beyond;
        report.rows.push_back(r);
      }
    };

    void compare(model const &m, capture const &cpu, capture const &gpu, check_report &report)
    {
      auto const &c{ m.cfg };
      comparer cmp{ report, -1 };
      cmp.floats("embed", cpu.embed, gpu.embed, 0);
      for(size_t vi{}; vi < cpu.visits.size(); ++vi)
      {
        auto const &a{ cpu.visits[vi] };
        auto const &b{ gpu.visits[vi] };
        auto const &lw{ m.layers[static_cast<size_t>(m.plan[vi].layer)] };
        cmp.visit = static_cast<int32_t>(vi);
        char const *const controllers[4]{ "q", "k", "v", "ffn" };
        for(size_t i{}; i < 4; ++i)
        {
          auto const pair{ std::string{ "pair." } + controllers[i] };
          auto const compressed{ std::string{ "compressed." } + controllers[i] };
          cmp.floats(pair.c_str(), a.pairs[i], b.pairs[i], 0);
          cmp.floats(compressed.c_str(), a.compressed[i], b.compressed[i], 0);
        }
        cmp.floats("inputs.q", a.inputs[0], b.inputs[0], 0);
        cmp.floats("inputs.k", a.inputs[1], b.inputs[1], 0);
        cmp.floats("inputs.v", a.inputs[2], b.inputs[2], 0);
        cmp.floats("q_proj", a.q_proj, b.q_proj, 0);
        cmp.floats("r_proj", a.r_proj, b.r_proj, 0);
        cmp.floats("k_proj", a.k_proj, b.k_proj, 0);
        cmp.floats("v_proj", a.v_proj, b.v_proj, 0);
        cmp.floats("k_taps", a.k_taps, b.k_taps, 0);
        cmp.floats("v_taps", a.v_taps, b.v_taps, 0);
        cmp.floats("k_conv", a.k_conv, b.k_conv, 0);
        cmp.floats("v_conv", a.v_conv, b.v_conv, 0);
        cmp.floats("q", a.q, b.q, 0);
        cmp.floats("r", a.r, b.r, 0);
        cmp.floats("sink", a.sink, b.sink, 0);
        cmp.floats("gate", a.gate, b.gate, 0);
        cmp.halves("k", a.k, b.k);
        cmp.halves("v", a.v, b.v);
        cmp.floats("conv.k", a.conv[0], b.conv[0], 0);
        cmp.floats("conv.v", a.conv[1], b.conv[1], 0);
        cmp.floor = 1e-4;
        cmp.floats("attended", a.attended, b.attended, 0);
        cmp.floor = 2e-5;
        cmp.floats("attn_proj", a.attn_proj, b.attn_proj, 0);
        cmp.floats("after_attention", a.after_attention, b.after_attention, 0);
        cmp.floats("conv.attn", a.conv[2], b.conv[2], 0);
        cmp.floats("ffn_input", a.ffn_input, b.ffn_input, 0);
        cmp.floats("router", a.router, b.router, 0);

        // The chosen experts: equal, or decided by scores closer than 1e-4.
        auto const k{ static_cast<size_t>(c.top_k) };
        auto const ne{ static_cast<size_t>(c.experts) };
        auto const tokens{ static_cast<size_t>(cpu.tokens) };
        std::vector<bool> rerouted(tokens);
        check_row routes{ cmp.visit, "experts" };
        float const *bias{ m.f32(lw.router_bias) };
        for(size_t t{}; t < tokens && a.experts.size() == b.experts.size() && a.experts.size() == tokens * k; ++t)
        {
          routes.count += static_cast<int64_t>(k);
          bool same{ true };
          for(size_t j{}; j < k; ++j)
          {
            same = same && a.experts[t * k + j] == b.experts[t * k + j];
          }
          if(same)
          {
            continue;
          }
          rerouted[t] = true;
          routes.different += static_cast<int64_t>(k);
          // The smallest gap between the scores of two experts ranked
          // differently by the two paths.
          auto const score{ [&](int32_t e) {
            float const l{ a.router[t * ne + static_cast<size_t>(e)] };
            return 1.0f / (1.0f + std::exp(-l)) + (bias ? bias[e] : 0.0f);
          } };
          double gap{};
          for(size_t j{}; j < k; ++j)
          {
            gap = std::max(gap, static_cast<double>(std::abs(score(a.experts[t * k + j]) - score(b.experts[t * k + j]))));
          }
          routes.worst = std::max(routes.worst, gap / 1e-4);
          if(gap > 1e-4)
          {
            routes.beyond += static_cast<int64_t>(k);
          }
        }
        if(a.experts.size() != b.experts.size())
        {
          routes.count = routes.beyond = static_cast<int64_t>(std::max(a.experts.size(), b.experts.size()));
        }
        cmp.add(routes);
        cmp.floats("expert_weights", a.expert_weights, b.expert_weights, 0, &rerouted, k);
        cmp.floats("expert_input", a.expert_input, b.expert_input, 1);
        cmp.floats("expert_input_max", a.expert_input_max, b.expert_input_max, 1);
        cmp.units = 2.0;
        cmp.floats("activations_raw", a.activations_raw, b.activations_raw, 0);
        cmp.units = 1.0;
        cmp.floats("activations", a.activations, b.activations, 1);
        cmp.floats("activation_max", a.activation_max, b.activation_max, 1);
        // Each route's part is rounded before the sum: one unit of each.
        std::vector<float> slack(a.ffn.size(), 0.0f);
        auto const hidden{ static_cast<size_t>(c.hidden) };
        for(size_t t{}; t < tokens && a.ffn_routes.size() == tokens * k * hidden; ++t)
        {
          for(size_t j{}; j < k; ++j)
          {
            for(size_t i{}; i < hidden; ++i)
            {
              slack[t * hidden + i] += bf16_ulp(a.ffn_routes[(t * k + j) * hidden + i]);
            }
          }
        }
        cmp.floats("ffn", a.ffn, b.ffn, 0, nullptr, 0, &slack);
        cmp.floats("partial", a.partial, b.partial, 0);
        cmp.floats("conv.ffn", a.conv[3], b.conv[3], 0);
      }
      cmp.visit = static_cast<int32_t>(cpu.visits.size());
      cmp.floats("hidden", cpu.hidden, gpu.hidden, 0);
      cmp.floats("logits", cpu.logits, gpu.logits, 0);
    }
  }

  check_report check_gpu(session &s, std::vector<int32_t> const &ids)
  {
    if(!s.gpu)
    {
      fail("this session has no Metal backend");
    }
    if(s.pos + static_cast<int64_t>(ids.size()) > s.context)
    {
      fail("the session's context (" + std::to_string(s.context) + " tokens) is full");
    }
    auto &m{ *s.model };
    std::lock_guard<std::mutex> const one{ m.running };
    std::unique_ptr<session, void (*)(session *)> twin{ new_session(m, s.context), free_session };
    check_report report;
    bool const was_capturing{ s.capturing };
    for(size_t i{}; i < ids.size(); i += max_chunk)
    {
      auto const n{ static_cast<int32_t>(std::min<size_t>(max_chunk, ids.size() - i)) };
      copy(*twin, s);
      s.capturing = true;
      forward(s, ids.data() + i, n);
      twin->capturing = true;
      metal_forward(*twin, ids.data() + i, n, &s.captured);
      compare(m, s.captured, twin->captured, report);
    }
    s.capturing = was_capturing;
    return report;
  }
}

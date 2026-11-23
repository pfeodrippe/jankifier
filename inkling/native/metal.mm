// The Metal backend: the forward pass of a chunk of tokens as one command
// buffer of compute kernels (kernels.metal), following cpu.cpp step by step.
//
// Weights are Metal buffers over the mapped model file (no copies). A
// session's caches are shared-memory Metal buffers, so the CPU path can read
// and continue them: tracing a token runs it on the CPU over the same state.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include "internal.hpp"

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <map>

namespace inkling
{
  namespace
  {
    char const *const kernel_source{
#include "kernels.metal"
    };

    // Mirrors of the kernels' parameter structs.
    struct embed_params
    {
      uint32_t h, slot, tmax;
      float eps;
    };

    struct vec_params
    {
      uint32_t t0, dst_t0, h, tmax, nsrc, src[6], has_query, query_row[3], nprev, prev[2], msg_row[3], tmp_in[3], tmp_msg[3],
        from_tmp;
      float eps;
    };

    struct ctl_params
    {
      uint32_t h, rank, tmax, tmp_in[3], tmp_msg[3];
    };

    struct lin_params
    {
      uint32_t rows, in, nt, mode;
      float cap;
    };

    struct conv_params
    {
      uint32_t ch, nt, mode, dst, tmax, h, heads;
      float norm;
      uint32_t keep;
    };

    struct kvs_params
    {
      uint32_t p0, slots, kvh;
      float clip, eps;
    };

    struct qp_params
    {
      uint32_t p0, heads, kvh, tmax, global;
      float qclip, rclip, log_floor, log_alpha;
    };

    struct rb_params
    {
      uint32_t heads, extent;
    };

    struct ab_params
    {
      uint32_t p0, nt, t0, tn, heads, kvh, slots, window, extent, nkp, rows, tmax;
      float scale;
    };

    struct att_params
    {
      uint32_t p0, heads, kvh, slots, window, extent;
      float scale;
    };

    struct rows_params
    {
      uint32_t p0, heads, kvh, slots, window, extent, most;
      float scale;
    };

    struct tap_params
    {
      uint32_t h, p0, slots, ntaps, tap, src_row;
    };

    // A matrix of linear_multi with its input and output.
    struct lin_part
    {
      tensor const *w;
      id<MTLBuffer> x, y;
    };

    struct multi_params
    {
      uint32_t in, nt, mode;
      float cap;
      uint32_t count;
      uint32_t ends[6];
    };

    struct split_params
    {
      uint32_t p0, heads, kvh, slots, extent, chunk, splits;
      float scale;
    };

    // att_split: at most this many chunks of keys, each at least this many keys.
    constexpr uint32_t split_most{ 64 };
    constexpr uint32_t split_least{ 512 };
    // Where the split starts (keys): measured faster alone from 2,000 tokens on (34.0
    // against 35.9 tokens a second), slower under contention at 1,364; four chunks.
    constexpr uint32_t split_from{ 4 * split_least };

    struct route_params
    {
      uint32_t h, ne, topk, mode, has_bias;
      float route_scale;
    };

    struct gu_params
    {
      uint32_t topk, rows, cols, quant;
      float gate_cap, up_cap, den;
    };

    struct aq_params
    {
      uint32_t width, mode;
    };

    struct dn_params
    {
      uint32_t topk, rows, cols, quant;
      float den;
    };

    // Residual stream slots, plus two for each controller's input and message
    // (up to 3 inputs computed together).
    constexpr uint32_t stream_slots{ 12 };
    constexpr uint32_t tmp_in_slot(uint32_t const z)
    {
      return stream_slots + 2 * z;
    }
    constexpr uint32_t tmp_msg_slot(uint32_t const z)
    {
      return stream_slots + 2 * z + 1;
    }
  }

  struct metal_backend
  {
    id<MTLDevice> device;
    id<MTLCommandQueue> queue;
    id<MTLComputePipelineState> embed, mix_norm, mix_pair, controller, linear1, linear4, linear_mm, multi1, multi4, tap_store, conv_fixed, conv_dyn, kv_store,
      q_prep, att1, att8, att32, att_split, att_merge, att_rows, att_rows_merge, rel_bias, att_scores, att_softmax, att_pv, route, gu_nv, gu_mx, act_quant, dn_nv,
      dn_mx;
    std::unordered_map<void const *, id<MTLBuffer>> weights;
    // Half-float copies of projection weights, for the batched kernels.
    std::unordered_map<void const *, id<MTLBuffer>> halves;
    std::vector<id<MTLBuffer>> message_queries;
    // Per layer: the relative-position projection transposed, F32 [extent, 16].
    std::vector<id<MTLBuffer>> rel;
    id<MTLBuffer> e4m3;
    id<MTLBuffer> dummy;
  };

  struct metal_session
  {
    metal_backend *backend{};
    uint32_t tmax{};
    std::vector<id<MTLBuffer>> k, v;
    std::vector<std::array<id<MTLBuffer>, 4>> conv;
    // A draft's check's inputs to each convolution (visit_cache::kept).
    std::vector<std::array<id<MTLBuffer>, 4>> kept;
    // The taps' ring for a draft model (session::tap_ring), when kept.
    id<MTLBuffer> taps;
    id<MTLBuffer> ids, stream, q, r, gate, sink, kraw, vraw, dynk, dynv, kc, vc, attended, out, ffn_in, xq, xmax, chosen,
      cw, act, amax, ffn, hidden, logits, rlogits, qg, bias, scores, inv, part;
    // A controller's normalized pair and its projection, for each of 3 inputs.
    id<MTLBuffer> pair[3], cmp[3];
    // Bytes of `scores`: the batched attention's scratch.
    size_t scores_bytes{};
    id<MTLBuffer> normed[3];
  };

  namespace
  {
    id<MTLLibrary> compile(id<MTLDevice> device, int tb, int nsg)
    {
      MTLCompileOptions *const options{ [MTLCompileOptions new] };
      options.preprocessorMacros = @{ @"TB" : @(tb), @"NSG" : @(nsg) };
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
      // The quantizers and the running softmax rely on IEEE behaviour.
      options.fastMathEnabled = NO;
#pragma clang diagnostic pop
      NSError *error{ nil };
      id<MTLLibrary> const lib{ [device newLibraryWithSource:@(kernel_source) options:options error:&error] };
      if(!lib)
      {
        fail(std::string{ "Metal kernels don't compile: " } + error.localizedDescription.UTF8String);
      }
      return lib;
    }

    id<MTLComputePipelineState> pipeline(id<MTLDevice> device, id<MTLLibrary> lib, char const *name, uint32_t threads)
    {
      id<MTLFunction> const fn{ [lib newFunctionWithName:@(name)] };
      if(!fn)
      {
        fail(std::string{ "no Metal kernel " } + name);
      }
      NSError *error{ nil };
      id<MTLComputePipelineState> const p{ [device newComputePipelineStateWithFunction:fn error:&error] };
      if(!p)
      {
        fail(std::string{ "Metal pipeline " } + name + ": " + error.localizedDescription.UTF8String);
      }
      if(p.maxTotalThreadsPerThreadgroup < threads)
      {
        fail(std::string{ "Metal kernel " } + name + " can't run " + std::to_string(threads) + " threads per group");
      }
      return p;
    }

    // A buffer over a tensor's bytes in the mapped model file.
    id<MTLBuffer> weight(metal_backend &b, tensor const *t, dtype expected)
    {
      if(!t)
      {
        return b.dummy;
      }
      if(t->type != expected)
      {
        fail("the tensor " + t->name + " is " + dtype_name(t->type) + ", and the Metal kernels need "
             + dtype_name(expected));
      }
      auto const it{ b.weights.find(t->data) };
      if(it != b.weights.end())
      {
        return it->second;
      }
      size_t const len{ (t->nbytes + 16383) / 16384 * 16384 };
      id<MTLBuffer> const buf{ [b.device newBufferWithBytesNoCopy:const_cast<void *>(t->data)
                                                           length:len
                                                          options:MTLResourceStorageModeShared
                                                      deallocator:nil] };
      if(!buf)
      {
        fail("can't make a Metal buffer of " + t->name);
      }
      b.weights.emplace(t->data, buf);
      return buf;
    }

    id<MTLBuffer> scratch_buffer(metal_backend &b, size_t bytes);

    // A BF16 matrix [rows, in] as IEEE halves, with zero rows up to a
    // multiple of 32, made on first use. A BF16 value below 2^-17 in
    // magnitude has no exact half: it is rounded (by less than 2^-25).
    id<MTLBuffer> half_weight(metal_backend &b, model const &m, tensor const *t)
    {
      auto const it{ b.halves.find(t->data) };
      if(it != b.halves.end())
      {
        return it->second;
      }
      auto const rows{ t->dim(0) };
      auto const in{ t->dim(1) };
      auto const padded{ (rows + 31) / 32 * 32 };
      id<MTLBuffer> const buf{ scratch_buffer(b, static_cast<size_t>(padded * in) * sizeof(_Float16)) };
      auto const *const src{ static_cast<uint16_t const *>(t->data) };
      auto *const dst{ static_cast<_Float16 *>(buf.contents) };
      m.workers->run(rows, 64, [&](int64_t r0, int64_t r1) {
        for(int64_t i{ r0 * in }; i < r1 * in; ++i)
        {
          dst[i] = static_cast<_Float16>(bf16_to_f32(src[i]));
        }
      });
      b.halves.emplace(t->data, buf);
      return buf;
    }

    id<MTLBuffer> scratch_buffer(metal_backend &b, size_t bytes)
    {
      id<MTLBuffer> const buf{ [b.device newBufferWithLength:std::max<size_t>(bytes, 16)
                                                     options:MTLResourceStorageModeShared] };
      if(!buf)
      {
        fail("can't allocate a Metal buffer of " + std::to_string(bytes) + " bytes");
      }
      return buf;
    }
  }

  metal_backend *metal_open(model &m)
  {
    @autoreleasepool
    {
      auto const &c{ m.cfg };
      // The kernels fix these sizes.
      if(c.hidden != 2304 || c.head_dim != 128 || c.local_head_dim != 128 || c.rel_dim != 16 || c.conv_taps != 4
         || c.experts != 128 || c.top_k != 8 || c.expert_width != 1152 || (c.loop && c.gate_rank != 64)
         || c.heads != c.local_heads || c.kv_heads != c.local_kv_heads)
      {
        return nullptr;
      }
      // The forward's bookkeeping holds at most 6 sources and 2 message
      // sources per kernel, in stream_slots slots: follow the plan and count
      // (as metal_forward does; specs/models/Stream.lean).
      {
        size_t blocks{}, previous{}, prelude{}, live{ 1 };
        for(auto const &visit : m.plan)
        {
          bool const looped{ c.loop && visit.layer == c.loop_start };
          if(looped && visit.pass == 0)
          {
            prelude = blocks;
          }
          else if(looped)
          {
            if(blocks < prelude + 1)
            {
              return nullptr;
            }
            live -= previous;
            previous = blocks - prelude;
            blocks = prelude;
          }
          if(visit.layer % c.residual_block == 0)
          {
            ++blocks;
            ++live;
          }
          if(blocks + 1 > 6 || previous > 2 || live > stream_slots)
          {
            return nullptr;
          }
        }
      }
      id<MTLDevice> const device{ MTLCreateSystemDefaultDevice() };
      if(!device)
      {
        return nullptr;
      }
      auto b{ std::make_unique<metal_backend>() };
      b->device = device;
      b->queue = [device newCommandQueue];
      id<MTLLibrary> const lib{ compile(device, 1, 1) };
      id<MTLLibrary> const lib4{ compile(device, 4, 1) };
      id<MTLLibrary> const lib8{ compile(device, 1, 8) };
      id<MTLLibrary> const lib32{ compile(device, 1, 32) };
      b->embed = pipeline(device, lib, "embed", 160);
      b->mix_norm = pipeline(device, lib, "mix_norm", 160);
      b->mix_pair = pipeline(device, lib, "mix_pair", 160);
      b->controller = pipeline(device, lib, "controller", 32);
      b->linear1 = pipeline(device, lib, "linear", 32);
      b->linear4 = pipeline(device, lib4, "linear", 32);
      b->multi1 = pipeline(device, lib, "linear_multi", 32);
      b->multi4 = pipeline(device, lib4, "linear_multi", 32);
      b->tap_store = pipeline(device, lib, "tap_store", 64);
      b->linear_mm = pipeline(device, lib, "linear_mm", 32);
      b->conv_fixed = pipeline(device, lib, "conv_fixed", 32);
      b->conv_dyn = pipeline(device, lib, "conv_dyn", 32);
      b->kv_store = pipeline(device, lib, "kv_store", 32);
      b->q_prep = pipeline(device, lib, "q_prep", 32);
      b->att1 = pipeline(device, lib, "attention", 32);
      b->att8 = pipeline(device, lib8, "attention", 256);
      b->att32 = pipeline(device, lib32, "attention", 1024);
      b->att_split = pipeline(device, lib8, "att_split", 256);
      b->att_merge = pipeline(device, lib, "att_merge", 32);
      b->att_rows = pipeline(device, lib8, "att_rows", 256);
      b->att_rows_merge = pipeline(device, lib, "att_rows_merge", 32);
      b->rel_bias = pipeline(device, lib, "rel_bias", 32);
      b->att_scores = pipeline(device, lib, "att_scores", 32);
      b->att_softmax = pipeline(device, lib, "att_softmax", 128);
      b->att_pv = pipeline(device, lib, "att_pv", 32);
      b->route = pipeline(device, lib, "route", 160);
      b->gu_nv = pipeline(device, lib, "gate_up_nvfp4", 32);
      b->gu_mx = pipeline(device, lib, "gate_up_mxfp8", 32);
      b->act_quant = pipeline(device, lib, "act_quant", 96);
      b->dn_nv = pipeline(device, lib, "down_nvfp4", 32);
      b->dn_mx = pipeline(device, lib, "down_mxfp8", 32);
      b->dummy = scratch_buffer(*b, 16384);
      b->e4m3 = scratch_buffer(*b, 256 * sizeof(float));
      auto *const table{ static_cast<float *>(b->e4m3.contents) };
      for(int i{}; i < 256; ++i)
      {
        table[i] = e4m3_to_f32(static_cast<uint8_t>(i));
      }
      // Buffers for every tensor the kernels read, made now so that a bad
      // dtype fails here.
      for(auto const &w : m.layers)
      {
        auto const &a{ w.attn };
        for(auto const t : { a.wq, a.wk, a.wv, a.wo, a.wr, a.gate, a.sink, a.rel_proj, a.q_scale, a.r_scale, w.router,
                             w.mlp_norm, w.attn_norm[0], w.attn_norm[1], w.attn_norm[2], w.attn_conv.weight,
                             w.mlp_conv.weight, a.k_conv.weight, a.k_conv.static_w, a.k_conv.weight_proj,
                             a.v_conv.weight, a.v_conv.static_w, a.v_conv.weight_proj })
        {
          weight(*b, t, dtype::bf16);
        }
        for(auto const t : { w.attn_query, w.mlp_query, w.router_bias, w.gate_up.amax, w.down.amax })
        {
          weight(*b, t, dtype::f32);
        }
        for(auto const &g : w.messages)
        {
          weight(*b, g.down, dtype::bf16);
          weight(*b, g.gain, dtype::bf16);
          weight(*b, g.forget, dtype::bf16);
        }
        weight(*b, w.gate_up.weight, dtype::u32);
        weight(*b, w.gate_up.scales, dtype::u8);
        weight(*b, w.down.weight, dtype::u32);
        weight(*b, w.down.scales, dtype::u8);
        id<MTLBuffer> mq{ b->dummy };
        if(!w.message_queries.empty())
        {
          mq = scratch_buffer(*b, w.message_queries.size() * sizeof(float));
          std::memcpy(mq.contents, w.message_queries.data(), w.message_queries.size() * sizeof(float));
        }
        b->message_queries.push_back(mq);
        auto const extent{ static_cast<size_t>(a.rel_extent) };
        auto const rd{ static_cast<size_t>(c.rel_dim) };
        id<MTLBuffer> const rel{ scratch_buffer(*b, extent * rd * sizeof(float)) };
        auto *const out{ static_cast<float *>(rel.contents) };
        for(size_t d{}; d < extent; ++d)
        {
          for(size_t i{}; i < rd; ++i)
          {
            out[d * rd + i] = a.rel_proj->get(static_cast<int64_t>(i * extent + d));
          }
        }
        b->rel.push_back(rel);
      }
      weight(*b, m.embed, dtype::bf16);
      weight(*b, m.unembed, dtype::bf16);
      weight(*b, m.embed_norm, dtype::bf16);
      weight(*b, m.out_norm, dtype::bf16);
      weight(*b, m.out_query, dtype::f32);
      return b.release();
    }
  }

  void metal_close(metal_backend *b)
  {
    delete b;
  }

  metal_session *metal_new_session(session &s)
  {
    @autoreleasepool
    {
      auto &m{ *s.model };
      auto &b{ *m.gpu };
      auto const &c{ m.cfg };
      auto g{ std::make_unique<metal_session>() };
      g->backend = &b;
      g->tmax = static_cast<uint32_t>(max_chunk);
      size_t const t{ g->tmax };
      size_t const h{ static_cast<size_t>(c.hidden) };
      size_t const f{ sizeof(float) };
      size_t const qw{ static_cast<size_t>(c.heads) * c.head_dim };
      size_t const kw{ static_cast<size_t>(c.kv_heads) * c.head_dim };
      for(auto &vc : s.caches)
      {
        id<MTLBuffer> const kb{ scratch_buffer(b, vc.kv_elements() * 2) };
        id<MTLBuffer> const vb{ scratch_buffer(b, vc.kv_elements() * 2) };
        vc.k = static_cast<uint16_t *>(kb.contents);
        vc.v = static_cast<uint16_t *>(vb.contents);
        g->k.push_back(kb);
        g->v.push_back(vb);
        std::array<id<MTLBuffer>, 4> hist;
        std::array<id<MTLBuffer>, 4> kept;
        for(size_t i{}; i < 4; ++i)
        {
          hist[i] = scratch_buffer(b, static_cast<size_t>(c.conv_taps - 1) * vc.conv_width[i] * f);
          vc.conv[i] = static_cast<float *>(hist[i].contents);
          kept[i] = scratch_buffer(b, static_cast<size_t>(max_rows) * vc.conv_width[i] * f);
          vc.kept[i] = static_cast<float *>(kept[i].contents);
        }
        g->conv.push_back(hist);
        g->kept.push_back(kept);
      }
      g->ids = scratch_buffer(b, t * sizeof(int32_t));
      g->stream = scratch_buffer(b, (stream_slots + 6) * t * h * f);
      for(size_t z{}; z < 3; ++z)
      {
        g->pair[z] = scratch_buffer(b, t * 2 * h * f);
        g->cmp[z] = scratch_buffer(b, t * 64 * f);
      }
      g->rlogits = scratch_buffer(b, t * c.experts * f);
      // The batched attention: queries by group (with a tile of slack),
      // biases, and scores [8 groups, rows, slots] for as many of the
      // chunk's tokens as fit in half a gigabyte (at least a tile's).
      size_t const per{ static_cast<size_t>(c.heads / c.kv_heads) };
      g->qg = scratch_buffer(b, (c.kv_heads * t * per + 32) * c.head_dim * f);
      g->bias = scratch_buffer(b, t * c.heads * std::max(c.rel_extent, c.window) * f);
      g->inv = scratch_buffer(b, t * c.heads * f);
      size_t const slots{ static_cast<size_t>((s.context + 31) / 32 * 32) };
      size_t const full{ c.kv_heads * ((t * per + 31) / 32 * 32) * slots * f };
      g->scores_bytes = std::min(full, std::max<size_t>(512u << 20, c.kv_heads * 32 * slots * f));
      g->scores = scratch_buffer(b, g->scores_bytes);
      // att_split's records: a head a chunk, 33 float4s.
      // att_rows' chunks: up to 16 tokens, 64 chunks each.
      g->part = scratch_buffer(b, static_cast<size_t>(16) * split_most * c.heads * 33 * 4 * f);
      for(auto &n : g->normed)
      {
        n = scratch_buffer(b, t * h * f);
      }
      g->q = scratch_buffer(b, t * qw * f);
      g->r = scratch_buffer(b, t * c.heads * c.rel_dim * f);
      g->gate = scratch_buffer(b, t * qw * f);
      g->sink = scratch_buffer(b, t * c.heads * f);
      g->kraw = scratch_buffer(b, t * kw * f);
      g->vraw = scratch_buffer(b, t * kw * f);
      g->dynk = scratch_buffer(b, t * c.kv_heads * c.conv_taps * f);
      g->dynv = scratch_buffer(b, t * c.kv_heads * c.conv_taps * f);
      g->kc = scratch_buffer(b, t * kw * f);
      g->vc = scratch_buffer(b, t * kw * f);
      g->attended = scratch_buffer(b, t * qw * f);
      g->out = scratch_buffer(b, t * h * f);
      g->ffn_in = scratch_buffer(b, t * h * f);
      g->xq = scratch_buffer(b, t * h * f);
      g->xmax = scratch_buffer(b, t * f);
      g->chosen = scratch_buffer(b, t * c.top_k * sizeof(uint32_t));
      g->cw = scratch_buffer(b, t * c.top_k * f);
      g->act = scratch_buffer(b, t * c.top_k * c.expert_width * f);
      g->amax = scratch_buffer(b, t * c.top_k * f);
      g->ffn = scratch_buffer(b, t * h * f);
      // Up to max_rows tokens' outputs (all_logits).
      g->hidden = scratch_buffer(b, std::max<size_t>(t, max_rows) * h * f);
      g->logits = scratch_buffer(b, static_cast<size_t>(max_rows) * (c.unpadded_vocab + 4) * f);
      return g.release();
    }
  }

  void metal_free_session(metal_session *g)
  {
    delete g;
  }

  uint16_t *metal_tap_ring(session &s, size_t const n)
  {
    @autoreleasepool
    {
      auto &g{ *s.gpu };
      g.taps = scratch_buffer(*g.backend, n * sizeof(uint16_t));
      return static_cast<uint16_t *>(g.taps.contents);
    }
  }

  void metal_forward(session &s, int32_t const *ids, int32_t const tokens, capture const *const force)
  {
    @autoreleasepool
    {
      auto &g{ *s.gpu };
      auto &b{ *g.backend };
      auto &m{ *s.model };
      auto const &c{ m.cfg };
      uint32_t const h{ static_cast<uint32_t>(c.hidden) };
      uint32_t const tmax{ g.tmax };
      uint32_t const nt{ static_cast<uint32_t>(tokens) };
      uint32_t const p0{ static_cast<uint32_t>(s.pos) };
      uint32_t const taps{ static_cast<uint32_t>(c.conv_taps) };
      std::memcpy(g.ids.contents, ids, nt * sizeof(int32_t));

      id<MTLCommandBuffer> cmd{ [b.queue commandBuffer] };
      id<MTLComputeCommandEncoder> e{ [cmd computeCommandEncoder] };
      // INK_GPU_PROFILE=1: every dispatch runs in its own command buffer and
      // its GPU time is added to its kernel's total, printed per forward.
      static bool const profile{ std::getenv("INK_GPU_PROFILE") != nullptr };
      std::map<std::string, std::pair<double, int>> profiled;
      std::string label;
      auto const started{ std::chrono::steady_clock::now() };
      auto const finish{ [&] {
        [e endEncoding];
        [cmd commit];
        [cmd waitUntilCompleted];
        if(cmd.status != MTLCommandBufferStatusCompleted)
        {
          fail(std::string{ "the Metal forward failed: " }
               + (cmd.error ? cmd.error.localizedDescription.UTF8String : "unknown error"));
        }
      } };
      auto const dispatched{ [&] {
        if(!profile)
        {
          return;
        }
        finish();
        auto &entry{ profiled[label] };
        entry.first += cmd.GPUEndTime - cmd.GPUStartTime;
        entry.second += 1;
        cmd = [b.queue commandBuffer];
        e = [cmd computeCommandEncoder];
      } };
      auto const use{ [&](id<MTLComputePipelineState> state, std::string name) {
        [e setComputePipelineState:state];
        label = std::move(name);
      } };
      auto const bind{ [&](NSUInteger index, id<MTLBuffer> buf) { [e setBuffer:buf offset:0 atIndex:index]; } };
      // INK_SKIP=label,label (labels as INK_GPU_PROFILE prints them) leaves those
      // dispatches out: the results are wrong, the time is what's left without them.
      static std::string const skip_list{ std::getenv("INK_SKIP") ? "," + std::string{ std::getenv("INK_SKIP") } + ","
                                                                   : std::string{} };
      auto const skipped{ [&] { return !skip_list.empty() && skip_list.find("," + label + ",") != std::string::npos; } };
      auto const groups{ [&](NSUInteger x, NSUInteger y, NSUInteger z, NSUInteger threads) {
        if(skipped())
        {
          return;
        }
        [e dispatchThreadgroups:MTLSizeMake(x, y, z) threadsPerThreadgroup:MTLSizeMake(threads, 1, 1)];
        dispatched();
      } };
      auto const threads{ [&](NSUInteger x, NSUInteger y, NSUInteger z) {
        if(skipped())
        {
          return;
        }
        [e dispatchThreads:MTLSizeMake(x, y, z) threadsPerThreadgroup:MTLSizeMake(std::min<NSUInteger>(x, 32), 1, 1)];
        dispatched();
      } };

      // Capturing or forcing: every stage runs in its own command buffer;
      // after it, sync copies its values out (capturing) and overwrites them
      // with the reference's (forcing).
      bool const staged{ s.capturing || force != nullptr };
      capture *const mine{ s.capturing ? &s.captured : nullptr };
      if(mine)
      {
        *mine = {};
        mine->tokens = tokens;
        mine->pos = s.pos;
        mine->visits.resize(m.plan.size());
      }
      if(force && (force->tokens != tokens || force->visits.size() != m.plan.size()))
      {
        fail("the forced capture is of another chunk");
      }
      auto const stage{ [&] {
        if(staged)
        {
          finish();
          cmd = [b.queue commandBuffer];
          e = [cmd computeCommandEncoder];
        }
        return staged;
      } };
      auto const sync{ [&](std::vector<float> *out, std::vector<float> const *in, id<MTLBuffer> buf, size_t offset, size_t n) {
        auto *const p{ static_cast<float *>(buf.contents) + offset };
        if(out)
        {
          out->assign(p, p + n);
        }
        if(in)
        {
          if(in->size() != n)
          {
            fail("a forced value has the wrong size");
          }
          std::memcpy(p, in->data(), n * sizeof(float));
        }
      } };

      // The current visit's capture and forced values, and a float field of
      // them in a buffer.
      visit_capture *vm{};
      visit_capture const *vf{};
      auto const field{ [&](std::vector<float> visit_capture::*f, id<MTLBuffer> buf, size_t offset, size_t n) {
        sync(vm ? &(vm->*f) : nullptr, vf ? &(vf->*f) : nullptr, buf, offset, n);
      } };

      // Residual stream slots.
      int32_t cur_visit{ -1 };
      if(s.record)
      {
        s.events.clear();
      }
      auto const event{ [&](stream_event::kind k, uint32_t slot) {
        if(s.record)
        {
          s.events.push_back({ k, cur_visit, static_cast<int32_t>(slot) });
        }
      } };
      std::vector<uint32_t> free_slots;
      for(uint32_t i{ stream_slots }; i-- > 0;)
      {
        free_slots.push_back(i);
      }
      auto const take{ [&] {
        if(free_slots.empty())
        {
          fail("out of residual stream slots");
        }
        auto const slot{ free_slots.back() };
        free_slots.pop_back();
        event(stream_event::kind::take, slot);
        return slot;
      } };
      uint32_t partial{ take() };
      std::vector<uint32_t> blocks, previous;
      size_t prelude_blocks{};
      uint32_t prelude_partial{};
      // The partial sum of every token, in the stream buffer.
      auto const partial_offset{ [&] { return static_cast<size_t>(partial) * tmax * h; } };

      {
        embed_params const p{ h, partial, tmax, c.norm_eps };
        use(b.embed, "embed");
        [e setBytes:&p length:sizeof(p) atIndex:0];
        bind(1, g.ids);
        bind(2, weight(b, m.embed, dtype::bf16));
        bind(3, weight(b, m.embed_norm, dtype::bf16));
        bind(4, g.stream);
        groups(nt, 1, 1, 160);
        event(stream_event::kind::write, partial);
        if(stage())
        {
          sync(mine ? &mine->embed : nullptr, force ? &force->embed : nullptr, g.stream, partial_offset(),
               static_cast<size_t>(nt) * h);
        }
      }

      // INK_NO_BATCHED=1 keeps the per-token kernels for batches too.
      static bool const batched{ std::getenv("INK_NO_BATCHED") == nullptr };
      auto const linear{ [&](tensor const *w, id<MTLBuffer> x, id<MTLBuffer> y, uint32_t count, uint32_t mode, float cap) {
        lin_params const p{ static_cast<uint32_t>(w->dim(0)), static_cast<uint32_t>(w->dim(1)), count, mode, cap };
        auto const name{ "linear " + std::to_string(p.rows) + "x" + std::to_string(p.in) };
        if(count > 16 && p.rows >= 512 && w->type == dtype::bf16 && batched)
        {
          // A batch and a big matrix: the matrix-product kernel.
          use(b.linear_mm, name + " (mm)");
          [e setBytes:&p length:sizeof(p) atIndex:0];
          bind(1, half_weight(b, m, w));
          bind(2, x);
          bind(3, y);
          groups((p.rows + 31) / 32, (count + 31) / 32, 1, 32);
          return;
        }
        // Tokens a simdgroup: 4 for several (8 or 16 rows in one tile, tried, were slower
        // than passes of 4). A token's sum is the same whatever this is (see `linear`).
        uint32_t const tb{ count > 1 ? 4u : 1u };
        use(tb == 4 ? b.linear4 : b.linear1, name);
        [e setBytes:&p length:sizeof(p) atIndex:0];
        bind(1, weight(b, w, dtype::bf16));
        bind(2, x);
        bind(3, y);
        groups(p.rows, (count + tb - 1) / tb, 1, 32);
      } };

      // Hidden states for a draft model (session::tap_visits): `count` rows of
      // `src` from row `src_row`, into the ring at positions p0 .. p0 + count.
      size_t const ntaps{ s.tap_visits.size() + 1 };
      auto const store_tap{ [&](id<MTLBuffer> src, uint32_t src_row, uint32_t count, uint32_t index) {
        tap_params const p{ h, p0, static_cast<uint32_t>(tap_slots), static_cast<uint32_t>(ntaps), index, src_row };
        use(b.tap_store, "tap_store");
        [e setBytes:&p length:sizeof(p) atIndex:0];
        bind(1, src);
        bind(2, g.taps);
        threads(h, count, 1);
      } };

      // Matrices of the same width, each with its input and output, in one
      // dispatch (linear_multi), each row as `linear` computes it; a batch of
      // more than 16 tokens takes them one at a time (the matrix-product kernel).
      auto const linear_many{ [&](std::vector<lin_part> const &parts, uint32_t count, uint32_t mode) {
        if((count > 16 && batched) || parts.size() > 6)
        {
          for(auto const &part : parts)
          {
            linear(part.w, part.x, part.y, count, mode, 0);
          }
          return;
        }
        multi_params p{};
        p.in = static_cast<uint32_t>(parts[0].w->dim(1));
        p.nt = count;
        p.mode = mode;
        p.count = static_cast<uint32_t>(parts.size());
        uint32_t end{};
        std::string name{ "linear" };
        for(size_t i{}; i < parts.size(); ++i)
        {
          end += static_cast<uint32_t>(parts[i].w->dim(0));
          p.ends[i] = end;
          name += (i == 0 ? " " : "+") + std::to_string(parts[i].w->dim(0));
        }
        uint32_t const tb{ count > 1 ? 4u : 1u };
        use(tb == 4 ? b.multi4 : b.multi1, name + "x" + std::to_string(p.in));
        [e setBytes:&p length:sizeof(p) atIndex:0];
        for(size_t i{}; i < 6; ++i)
        {
          auto const &part{ parts[i < parts.size() ? i : 0] };
          bind(1 + i, weight(b, part.w, dtype::bf16));
          bind(8 + i, part.y);
          bind(14 + i, part.x);
        }
        groups(end, (count + tb - 1) / tb, 1, 32);
      } };

      // Sublayer inputs: each the mix of the sources by `query` (row
      // query_row, or the last source as is when there is no query), through
      // the controller when the visit has messages, normalized by `norm` and
      // rounded, into dst (see mix_norm). Up to 3 inputs of the same sources
      // are computed together, each exactly as alone.
      struct vec_input
      {
        uint32_t query_row;
        uint32_t message_index;
        tensor const *norm;
        id<MTLBuffer> dst;
      };
      auto const vec{ [&](uint32_t t0, uint32_t count, std::vector<uint32_t> const &src, tensor const *query,
                          layer_weights const *messages, std::vector<vec_input> const &ins) {
        uint32_t const n{ static_cast<uint32_t>(ins.size()) };
        vec_params p{};
        p.t0 = t0;
        p.h = h;
        p.tmax = tmax;
        p.nsrc = static_cast<uint32_t>(src.size());
        for(size_t i{}; i < src.size(); ++i)
        {
          p.src[i] = src[i];
        }
        for(auto const slot : src)
        {
          event(stream_event::kind::read, slot);
        }
        if(messages)
        {
          for(auto const slot : previous)
          {
            event(stream_event::kind::read, slot);
          }
        }
        p.has_query = query ? 1 : 0;
        for(uint32_t z{}; z < n; ++z)
        {
          p.query_row[z] = ins[z].query_row;
          p.msg_row[z] = ins[z].message_index;
          p.tmp_in[z] = tmp_in_slot(z);
          p.tmp_msg[z] = tmp_msg_slot(z);
        }
        p.eps = c.norm_eps;
        if(messages)
        {
          p.nprev = static_cast<uint32_t>(previous.size());
          for(size_t i{}; i < previous.size() && i < 2; ++i)
          {
            p.prev[i] = previous[i];
          }
          use(b.mix_pair, "mix_pair");
          [e setBytes:&p length:sizeof(p) atIndex:0];
          bind(1, g.stream);
          bind(2, weight(b, query, dtype::f32));
          bind(3, b.message_queries[static_cast<size_t>(messages->index)]);
          for(uint32_t z{}; z < 3; ++z)
          {
            bind(4 + z, g.pair[z < n ? z : 0]);
          }
          groups(count, n, 1, 160);
          std::vector<lin_part> downs;
          for(uint32_t z{}; z < n; ++z)
          {
            auto const mi{ ins[z].message_index };
            if(stage())
            {
              sync(vm ? &vm->pairs[mi] : nullptr, vf ? &vf->pairs[mi] : nullptr, g.pair[z], 0,
                   static_cast<size_t>(count) * 2 * h);
            }
            downs.push_back({ messages->messages[mi].down, g.pair[z], g.cmp[z] });
          }
          linear_many(downs, count, 1);
          for(uint32_t z{}; z < n && stage(); ++z)
          {
            sync(vm ? &vm->compressed[ins[z].message_index] : nullptr, vf ? &vf->compressed[ins[z].message_index] : nullptr,
                 g.cmp[z], 0, static_cast<size_t>(count) * c.gate_rank);
          }
          ctl_params cp{ h, static_cast<uint32_t>(c.gate_rank), tmax, {}, {} };
          use(b.controller, "controller");
          for(uint32_t z{}; z < 3; ++z)
          {
            auto const zz{ z < n ? z : 0 };
            auto const &gate{ messages->messages[ins[zz].message_index] };
            cp.tmp_in[z] = tmp_in_slot(z);
            cp.tmp_msg[z] = tmp_msg_slot(z);
            uint32_t const at{ z == 0 ? 1u : 2u + 3u * z };
            bind(at, g.cmp[zz]);
            bind(at + 1, weight(b, gate.gain, dtype::bf16));
            bind(at + 2, weight(b, gate.forget, dtype::bf16));
          }
          [e setBytes:&cp length:sizeof(cp) atIndex:0];
          bind(4, g.stream);
          threads(h, count, n);
          // Then normalize what the controller left in tmp_in.
          p.from_tmp = 1;
        }
        use(b.mix_norm, "mix_norm");
        [e setBytes:&p length:sizeof(p) atIndex:0];
        bind(1, g.stream);
        bind(2, p.has_query && !p.from_tmp ? weight(b, query, dtype::f32) : b.dummy);
        for(uint32_t z{}; z < 3; ++z)
        {
          auto const zz{ z < n ? z : 0 };
          bind(z == 0 ? 7 : 7 + 2 * z, weight(b, ins[zz].norm, dtype::bf16));
          bind(z == 0 ? 8 : 8 + 2 * z, ins[zz].dst);
        }
        groups(count, n, 1, 160);
      } };

      // kept: where a draft's check keeps the inputs (all_logits), or nil.
      auto const conv_fixed{ [&](short_conv const &cv, id<MTLBuffer> in, id<MTLBuffer> hist, id<MTLBuffer> out,
                                 uint32_t mode, uint32_t dst, id<MTLBuffer> kept) {
        conv_params const p{ static_cast<uint32_t>(cv.channels), nt, mode, dst, tmax, h, 1,
                             1.0f / std::sqrt(static_cast<float>(taps + 1)), kept ? 1u : 0u };
        use(b.conv_fixed, "conv_fixed");
        [e setBytes:&p length:sizeof(p) atIndex:0];
        bind(1, weight(b, cv.weight, dtype::bf16));
        bind(2, in);
        bind(3, hist);
        bind(4, out);
        bind(5, g.stream);
        bind(6, kept ? kept : b.dummy);
        threads(p.ch, 1, 1);
        if(mode >= 2)
        {
          event(stream_event::kind::read, dst);
        }
        if(mode >= 1)
        {
          event(stream_event::kind::write, dst);
        }
      } };

      // Keys or values: projection, short convolution (fixed or projected).
      auto const kv_conv{ [&](short_conv const &cv, tensor const *proj, id<MTLBuffer> x, id<MTLBuffer> raw,
                              id<MTLBuffer> dyn, id<MTLBuffer> hist, id<MTLBuffer> kept, id<MTLBuffer> out,
                              std::vector<float> visit_capture::*f_proj, std::vector<float> visit_capture::*f_taps,
                              std::vector<float> visit_capture::*f_conv) {
        size_t const width{ static_cast<size_t>(nt) * cv.channels };
        if(proj)
        {
          linear(proj, x, raw, nt, 1, 0);
        }
        if(stage())
        {
          field(f_proj, raw, 0, width);
        }
        if(!cv.weight_proj)
        {
          conv_fixed(cv, raw, hist, out, 0, 0, kept);
        }
        else
        {
          linear(cv.weight_proj, x, dyn, nt, 1, 0);
          if(stage())
          {
            field(f_taps, dyn, 0, static_cast<size_t>(nt) * cv.heads * taps);
          }
          conv_params const p{ static_cast<uint32_t>(cv.channels), nt, 0, 0, tmax, h, static_cast<uint32_t>(cv.heads),
                               1.0f / std::sqrt(static_cast<float>(2 * taps + 1)), kept ? 1u : 0u };
          use(b.conv_dyn, "conv_dyn");
          [e setBytes:&p length:sizeof(p) atIndex:0];
          bind(1, weight(b, cv.static_w, dtype::bf16));
          bind(2, dyn);
          bind(3, raw);
          bind(4, hist);
          bind(5, out);
          bind(6, kept ? kept : b.dummy);
          threads(p.ch, 1, 1);
        }
        if(stage())
        {
          field(f_conv, out, 0, width);
        }
      } };

      bool const quant{ m.quantize_expert_inputs };
      size_t const fl{ sizeof(float) };
      size_t const qw{ static_cast<size_t>(c.heads) * c.head_dim };
      for(size_t vi{}; vi < m.plan.size(); ++vi)
      {
        cur_visit = static_cast<int32_t>(vi);
        vm = mine ? &mine->visits[vi] : nullptr;
        vf = force ? &force->visits[vi] : nullptr;
        auto const &visit{ m.plan[vi] };
        auto const &lw{ m.layers[static_cast<size_t>(visit.layer)] };
        auto const &a{ lw.attn };
        auto const &vc{ s.caches[vi] };
        bool const looped{ c.loop && visit.layer == c.loop_start };
        if(looped && visit.pass == 0)
        {
          prelude_blocks = blocks.size();
          prelude_partial = partial;
        }
        else if(looped)
        {
          // The previous pass's blocks and partial become the messages'
          // sources; the stream restarts from the prelude.
          for(auto const slot : previous)
          {
            free_slots.push_back(slot);
            event(stream_event::kind::release, slot);
          }
          previous.assign(blocks.begin() + static_cast<ptrdiff_t>(prelude_blocks) + 1, blocks.end());
          previous.push_back(partial);
          blocks.resize(prelude_blocks);
          partial = prelude_partial;
          event(stream_event::kind::restart, partial);
        }
        if(s.tap_ring)
        {
          // The partial sum entering this visit, for a draft model.
          auto const at{ std::find(s.tap_visits.begin(), s.tap_visits.end(), static_cast<int32_t>(vi)) };
          if(at != s.tap_visits.end())
          {
            store_tap(g.stream, partial * tmax, nt, static_cast<uint32_t>(at - s.tap_visits.begin()));
          }
        }
        layer_weights const *const messages{ visit.pass > 0 ? &lw : nullptr };

        // Attention inputs.
        std::vector<uint32_t> src{ blocks };
        src.push_back(partial);
        tensor const *const query{ blocks.empty() ? nullptr : lw.attn_query };
        bool const multi_query{ query && query->shape.size() == 2 };
        bool const same_norm{ lw.attn_norm[0] == lw.attn_norm[1] && lw.attn_norm[1] == lw.attn_norm[2] };
        bool const single{ !messages && !multi_query && same_norm };
        id<MTLBuffer> in[3];
        {
          std::vector<vec_input> ins;
          for(uint32_t i{}; i < (single ? 1u : 3u); ++i)
          {
            ins.push_back({ multi_query ? i : 0, i, lw.attn_norm[i], g.normed[i] });
          }
          vec(0, nt, src, query, messages, ins);
          for(uint32_t i{}; i < 3; ++i)
          {
            in[i] = g.normed[single ? 0 : i];
          }
        }
        if(stage())
        {
          for(size_t i{}; i < 3; ++i)
          {
            sync(vm ? &vm->inputs[i] : nullptr, (vf && (i == 0 || !single)) ? &vf->inputs[i] : nullptr, in[i], 0,
                 static_cast<size_t>(nt) * h);
          }
        }

        // Projections in one dispatch (keys and values from their own inputs).
        bool const kv_too{ a.wk->dim(1) == a.wq->dim(1) && a.wv->dim(1) == a.wq->dim(1) };
        {
          std::vector<lin_part> parts{
            { a.wq, in[0], g.q }, { a.wr, in[0], g.r }, { a.gate, in[0], g.gate }, { a.sink, in[0], g.sink } };
          if(kv_too)
          {
            parts.push_back({ a.wk, in[1], g.kraw });
            parts.push_back({ a.wv, in[2], g.vraw });
          }
          linear_many(parts, nt, 1);
        }
        if(stage())
        {
          field(&visit_capture::q_proj, g.q, 0, nt * qw);
          field(&visit_capture::r_proj, g.r, 0, static_cast<size_t>(nt) * c.heads * c.rel_dim);
        }
        kv_conv(a.k_conv, kv_too ? nullptr : a.wk, in[1], g.kraw, g.dynk, g.conv[vi][0], s.all_logits ? g.kept[vi][0] : nil, g.kc, &visit_capture::k_proj,
                &visit_capture::k_taps, &visit_capture::k_conv);
        kv_conv(a.v_conv, kv_too ? nullptr : a.wv, in[2], g.vraw, g.dynv, g.conv[vi][1], s.all_logits ? g.kept[vi][1] : nil, g.vc, &visit_capture::v_proj,
                &visit_capture::v_taps, &visit_capture::v_conv);
        {
          kvs_params const p{ p0, static_cast<uint32_t>(vc.slots), static_cast<uint32_t>(a.kv_heads), c.qk_clip,
                              c.norm_eps };
          use(b.kv_store, "kv_store");
          [e setBytes:&p length:sizeof(p) atIndex:0];
          bind(1, g.kc);
          bind(2, g.vc);
          bind(3, g.k[vi]);
          bind(4, g.v[vi]);
          groups(p.kvh, nt, 2, 32);
        }
        {
          qp_params const p{ p0, static_cast<uint32_t>(a.heads), static_cast<uint32_t>(a.kv_heads), tmax,
                             a.window == 0 ? 1u : 0u, c.qk_clip, c.rel_clip, c.log_floor, c.log_alpha };
          use(b.q_prep, "q_prep");
          [e setBytes:&p length:sizeof(p) atIndex:0];
          bind(1, g.q);
          bind(2, g.r);
          bind(3, weight(b, a.q_scale, dtype::bf16));
          bind(4, weight(b, a.r_scale, dtype::bf16));
          bind(5, g.qg);
          groups(p.heads, nt, 1, 32);
        }
        if(stage())
        {
          size_t const kw{ static_cast<size_t>(a.kv_heads) * a.head_dim };
          field(&visit_capture::q, g.q, 0, nt * qw);
          field(&visit_capture::r, g.r, 0, static_cast<size_t>(nt) * c.heads * c.rel_dim);
          field(&visit_capture::sink, g.sink, 0, static_cast<size_t>(nt) * c.heads);
          field(&visit_capture::gate, g.gate, 0, nt * qw);
          sync(vm ? &vm->conv[0] : nullptr, vf ? &vf->conv[0] : nullptr, g.conv[vi][0], 0, (taps - 1) * kw);
          sync(vm ? &vm->conv[1] : nullptr, vf ? &vf->conv[1] : nullptr, g.conv[vi][1], 0, (taps - 1) * kw);
          if(vm)
          {
            vm->k.resize(nt * kw);
            vm->v.resize(nt * kw);
          }
          for(uint32_t t{}; t < nt; ++t)
          {
            auto const row{ static_cast<size_t>(vc.slot(static_cast<int32_t>(p0 + t))) * kw };
            if(vm)
            {
              std::memcpy(vm->k.data() + t * kw, vc.k + row, kw * 2);
              std::memcpy(vm->v.data() + t * kw, vc.v + row, kw * 2);
            }
            if(vf)
            {
              std::memcpy(vc.k + row, vf->k.data() + t * kw, kw * 2);
              std::memcpy(vc.v + row, vf->v.data() + t * kw, kw * 2);
            }
          }
        }
        if(nt > 16 && batched)
        {
          // A batch: attention as matrix products (see att_scores).
          char const *const kind{ a.window == 0 ? " (global)" : " (local)" };
          rb_params const rb{ static_cast<uint32_t>(a.heads), static_cast<uint32_t>(a.rel_extent) };
          use(b.rel_bias, "rel_bias");
          [e setBytes:&rb length:sizeof(rb) atIndex:0];
          bind(1, g.r);
          bind(2, b.rel[static_cast<size_t>(visit.layer)]);
          bind(3, g.bias);
          threads(rb.extent, rb.heads, nt);
          uint32_t const per{ static_cast<uint32_t>(a.heads / a.kv_heads) };
          uint32_t const covered{ a.window > 0 ? static_cast<uint32_t>(vc.slots) : p0 + nt };
          ab_params p{};
          p.p0 = p0;
          p.nt = nt;
          p.heads = static_cast<uint32_t>(a.heads);
          p.kvh = static_cast<uint32_t>(a.kv_heads);
          p.slots = static_cast<uint32_t>(vc.slots);
          p.window = static_cast<uint32_t>(a.window);
          p.extent = static_cast<uint32_t>(a.rel_extent);
          p.nkp = (covered + 31) / 32 * 32;
          p.tmax = tmax;
          p.scale = 1.0f / std::sqrt(static_cast<float>(a.head_dim));
          // As many tokens at a time as the scores scratch holds.
          size_t const max_rows{ g.scores_bytes / (static_cast<size_t>(p.kvh) * p.nkp * fl) / 32 * 32 };
          uint32_t const step{ std::max<uint32_t>(1, std::min<uint32_t>(nt, static_cast<uint32_t>(max_rows / per))) };
          for(uint32_t t0{}; t0 < nt; t0 += step)
          {
            p.t0 = t0;
            p.tn = std::min(step, nt - t0);
            p.rows = (p.tn * per + 31) / 32 * 32;
            use(b.att_scores, std::string{ "att_scores" } + kind);
            [e setBytes:&p length:sizeof(p) atIndex:0];
            bind(1, g.qg);
            bind(2, g.k[vi]);
            bind(3, g.bias);
            bind(4, g.scores);
            groups(p.nkp / 32, p.rows / 32, p.kvh, 32);
            use(b.att_softmax, std::string{ "att_softmax" } + kind);
            [e setBytes:&p length:sizeof(p) atIndex:0];
            bind(1, g.scores);
            bind(2, g.sink);
            bind(3, g.inv);
            groups(p.heads, p.tn, 1, 128);
            use(b.att_pv, std::string{ "att_pv" } + kind);
            [e setBytes:&p length:sizeof(p) atIndex:0];
            bind(1, g.scores);
            bind(2, g.v[vi]);
            bind(3, g.inv);
            bind(4, g.gate);
            bind(5, g.attended);
            groups(a.head_dim / 32, p.rows / 32, p.kvh, 32);
          }
        }
        else if(nt <= 16 && a.heads % a.kv_heads == 0 && a.heads / a.kv_heads <= 4 && a.head_dim == 128)
        {
          // A few tokens (one decoded, or a draft's check): att_rows, a token's keys in
          // chunks that depend on its own position only, then att_rows_merge.
          uint32_t const last{ p0 + nt - 1 };
          uint32_t const first_last{ a.window > 0 && last + 1 > static_cast<uint32_t>(a.window) ? last + 1 - static_cast<uint32_t>(a.window) : 0 };
          uint32_t const keys_last{ last + 1 - first_last };
          uint32_t const c64{ (keys_last + 63) / 64 };
          uint32_t const chunk_last{ std::max(256u, (c64 + 63) / 64 * 64) };
          uint32_t const most{ (keys_last + chunk_last - 1) / chunk_last };
          rows_params const p{ p0, static_cast<uint32_t>(a.heads), static_cast<uint32_t>(a.kv_heads),
                               static_cast<uint32_t>(vc.slots), static_cast<uint32_t>(a.window),
                               static_cast<uint32_t>(a.rel_extent), split_most,
                               1.0f / std::sqrt(static_cast<float>(a.head_dim)) };
          std::string const kind{ a.window == 0 ? "global" : "local" };
          use(b.att_rows, "attention (" + kind + ", rows)");
          [e setBytes:&p length:sizeof(p) atIndex:0];
          bind(1, g.q);
          bind(2, g.r);
          bind(3, b.rel[static_cast<size_t>(visit.layer)]);
          bind(4, g.k[vi]);
          bind(5, g.v[vi]);
          bind(6, g.part);
          groups(p.kvh, most, nt, 32 * 8);
          use(b.att_rows_merge, "attention (" + kind + ", merge)");
          [e setBytes:&p length:sizeof(p) atIndex:0];
          bind(1, g.part);
          bind(2, g.sink);
          bind(3, g.gate);
          bind(4, g.attended);
          groups(p.heads, nt, 1, 32);
        }
        else if(m.split_attention && nt == 1 && a.window == 0 && p0 + 1 >= split_from
                && a.heads % a.kv_heads == 0 && a.heads / a.kv_heads <= 4 && a.head_dim == 128)
        {
          // One token over a long context: the keys split in chunks (att_split),
          // then the chunks merged (att_merge).
          uint32_t const keys{ p0 + 1 };
          uint32_t const splits{ std::min(split_most, keys / split_least) };
          uint32_t const chunk{ (keys + splits - 1) / splits };
          split_params const p{ p0, static_cast<uint32_t>(a.heads), static_cast<uint32_t>(a.kv_heads),
                                static_cast<uint32_t>(vc.slots), static_cast<uint32_t>(a.rel_extent), chunk, splits,
                                1.0f / std::sqrt(static_cast<float>(a.head_dim)) };
          use(b.att_split, "attention (global, split)");
          [e setBytes:&p length:sizeof(p) atIndex:0];
          bind(1, g.q);
          bind(2, g.r);
          bind(3, b.rel[static_cast<size_t>(visit.layer)]);
          bind(4, g.k[vi]);
          bind(5, g.v[vi]);
          bind(6, g.part);
          groups(p.kvh, splits, 1, 32 * 8);
          use(b.att_merge, "attention (global, merge)");
          [e setBytes:&p length:sizeof(p) atIndex:0];
          bind(1, g.part);
          bind(2, g.sink);
          bind(3, g.gate);
          bind(4, g.attended);
          groups(p.heads, 1, 1, 32);
        }
        else
        {
          att_params const p{ p0, static_cast<uint32_t>(a.heads), static_cast<uint32_t>(a.kv_heads),
                              static_cast<uint32_t>(vc.slots), static_cast<uint32_t>(a.window),
                              static_cast<uint32_t>(a.rel_extent), 1.0f / std::sqrt(static_cast<float>(a.head_dim)) };
          // Lanes per head, by how many keys the chunk's last token sees.
          uint32_t const keys{ a.window > 0 ? std::min(p0 + nt, static_cast<uint32_t>(a.window)) : p0 + nt };
          uint32_t const nsg{ keys <= 64 ? 1u : keys <= 2048 ? 8u : 32u };
          use(nsg == 1 ? b.att1 : nsg == 8 ? b.att8 : b.att32, a.window == 0 ? "attention (global)" : "attention (local)");
          [e setBytes:&p length:sizeof(p) atIndex:0];
          bind(1, g.q);
          bind(2, g.r);
          bind(3, g.sink);
          bind(4, g.gate);
          bind(5, b.rel[static_cast<size_t>(visit.layer)]);
          bind(6, g.k[vi]);
          bind(7, g.v[vi]);
          bind(8, g.attended);
          groups(p.heads, nt, 1, 32 * nsg);
        }
        if(stage())
        {
          field(&visit_capture::attended, g.attended, 0, nt * qw);
        }
        linear(a.wo, g.attended, g.out, nt, 1, 0);
        if(stage())
        {
          field(&visit_capture::attn_proj, g.out, 0, static_cast<size_t>(nt) * h);
        }
        if(visit.layer % c.residual_block == 0)
        {
          event(stream_event::kind::push, partial);
          blocks.push_back(partial);
          partial = take();
          conv_fixed(lw.attn_conv, g.out, g.conv[vi][2], b.dummy, 1, partial, s.all_logits ? g.kept[vi][2] : nil);
        }
        else
        {
          conv_fixed(lw.attn_conv, g.out, g.conv[vi][2], b.dummy, 2, partial, s.all_logits ? g.kept[vi][2] : nil);
        }
        if(stage())
        {
          field(&visit_capture::after_attention, g.stream, partial_offset(), static_cast<size_t>(nt) * h);
          sync(vm ? &vm->conv[2] : nullptr, vf ? &vf->conv[2] : nullptr, g.conv[vi][2], 0, static_cast<size_t>(taps - 1) * h);
        }

        // Feed-forward: input, routing, experts.
        src = blocks;
        src.push_back(partial);
        vec(0, nt, src, lw.mlp_query, messages, { { 0, 3, lw.mlp_norm, g.ffn_in } });
        if(stage())
        {
          field(&visit_capture::ffn_input, g.ffn_in, 0, static_cast<size_t>(nt) * h);
        }
        auto const &gu{ lw.gate_up };
        auto const &dn{ lw.down };
        {
          route_params const p{ h, static_cast<uint32_t>(c.experts), static_cast<uint32_t>(c.top_k),
                                quant ? (gu.nvfp4 ? 1u : 2u) : 0u, lw.router_bias ? 1u : 0u, c.route_scale };
          linear(lw.router, g.ffn_in, g.rlogits, nt, 0, 0);
          use(b.route, "route");
          [e setBytes:&p length:sizeof(p) atIndex:0];
          bind(1, g.ffn_in);
          bind(2, g.rlogits);
          bind(3, weight(b, lw.router_bias, dtype::f32));
          bind(4, g.xq);
          bind(5, g.xmax);
          bind(6, g.chosen);
          bind(7, g.cw);
          groups(nt, 1, 1, 160);
        }
        uint32_t const routes{ nt * static_cast<uint32_t>(c.top_k) };

        if(stage())
        {
          field(&visit_capture::router, g.rlogits, 0, static_cast<size_t>(nt) * c.experts);
          field(&visit_capture::expert_weights, g.cw, 0, routes);
          field(&visit_capture::expert_input, g.xq, 0, static_cast<size_t>(nt) * h);
          auto *const chosen{ static_cast<uint32_t *>(g.chosen.contents) };
          if(vm)
          {
            vm->experts.assign(chosen, chosen + routes);
            auto const *const xmax{ static_cast<float const *>(g.xmax.contents) };
            // Only NVFP4 inputs have a per-token maximum.
            vm->expert_input_max.assign(nt, 0.0f);
            if(quant && gu.nvfp4)
            {
              vm->expert_input_max.assign(xmax, xmax + nt);
            }
          }
          if(vf)
          {
            std::copy(vf->experts.begin(), vf->experts.end(), chosen);
            std::memcpy(g.xmax.contents, vf->expert_input_max.data(), nt * fl);
          }
        }
        {
          gu_params const p{ static_cast<uint32_t>(c.top_k), static_cast<uint32_t>(gu.rows),
                             static_cast<uint32_t>(gu.cols), quant ? 1u : 0u, c.gate_cap, c.up_cap,
                             gu.nvfp4 ? m.f32(gu.denominator)[0] : 1.0f };
          // One route at a time, also for a batch: running the routes by
          // expert, so that an expert's rows are decoded once for several
          // tokens, measured slower (3.7 against 3.2 ms for 64 tokens). For a
          // draft's check (8 tokens, about 30 experts for 64 routes) too, in
          // three versions (an 8-row forward 74 -> 88, 95, 102 ms): the routes
          // of one expert read its weights at about the same time, from the
          // cache, so grouping saves little memory traffic and costs parallelism.
          use(gu.nvfp4 ? b.gu_nv : b.gu_mx, gu.nvfp4 ? "gate_up nvfp4" : "gate_up mxfp8");
          [e setBytes:&p length:sizeof(p) atIndex:0];
          bind(1, weight(b, gu.weight, dtype::u32));
          bind(2, weight(b, gu.scales, dtype::u8));
          if(gu.nvfp4)
          {
            bind(3, weight(b, gu.amax, dtype::f32));
            bind(5, g.xmax);
          }
          bind(4, g.xq);
          bind(6, g.chosen);
          bind(7, g.cw);
          bind(8, b.e4m3);
          bind(9, g.act);
          groups(p.rows / (gu.nvfp4 ? 4 : 4), routes, 1, 32); // GU_ROWS
        }
        if(stage())
        {
          field(&visit_capture::activations_raw, g.act, 0, static_cast<size_t>(routes) * c.expert_width);
        }
        if(quant)
        {
          aq_params const p{ static_cast<uint32_t>(dn.cols), dn.nvfp4 ? 1u : 2u };
          use(b.act_quant, "act_quant");
          [e setBytes:&p length:sizeof(p) atIndex:0];
          bind(1, g.act);
          bind(2, g.amax);
          groups(routes, 1, 1, 96);
        }
        if(stage())
        {
          field(&visit_capture::activations, g.act, 0, static_cast<size_t>(routes) * c.expert_width);
          if(vm)
          {
            auto const *const amax{ static_cast<float const *>(g.amax.contents) };
            vm->activation_max.assign(routes, 0.0f);
            if(quant && dn.nvfp4)
            {
              vm->activation_max.assign(amax, amax + routes);
            }
          }
          if(vf)
          {
            std::memcpy(g.amax.contents, vf->activation_max.data(), routes * fl);
          }
        }
        {
          dn_params const p{ static_cast<uint32_t>(c.top_k), static_cast<uint32_t>(dn.rows),
                             static_cast<uint32_t>(dn.cols), quant ? 1u : 0u,
                             dn.nvfp4 ? m.f32(dn.denominator)[0] : 1.0f };
          use(dn.nvfp4 ? b.dn_nv : b.dn_mx, dn.nvfp4 ? "down nvfp4" : "down mxfp8");
          [e setBytes:&p length:sizeof(p) atIndex:0];
          bind(1, weight(b, dn.weight, dtype::u32));
          bind(2, weight(b, dn.scales, dtype::u8));
          if(dn.nvfp4)
          {
            bind(3, weight(b, dn.amax, dtype::f32));
            bind(5, g.amax);
          }
          bind(4, g.act);
          bind(6, g.chosen);
          bind(8, b.e4m3);
          bind(9, g.ffn);
          groups(p.rows / 4, nt, 1, 32); // DN_ROWS, and 4 for MXFP8
        }
        if(stage())
        {
          field(&visit_capture::ffn, g.ffn, 0, static_cast<size_t>(nt) * h);
        }
        conv_fixed(lw.mlp_conv, g.ffn, g.conv[vi][3], b.dummy, 3, partial, s.all_logits ? g.kept[vi][3] : nil);
        if(stage())
        {
          field(&visit_capture::partial, g.stream, partial_offset(), static_cast<size_t>(nt) * h);
          sync(vm ? &vm->conv[3] : nullptr, vf ? &vf->conv[3] : nullptr, g.conv[vi][3], 0, static_cast<size_t>(taps - 1) * h);
        }
      }

      // Output of the last token: mix, norm, unembed, softcap.
      cur_visit = static_cast<int32_t>(m.plan.size());
      vm = nullptr;
      vf = nullptr;
      std::vector<uint32_t> src{ blocks };
      src.push_back(partial);
      // Every token's (all_logits), or the last one's; with taps, every token is
      // normalized (for a draft model) and the logits' rows are the last `outs`.
      uint32_t const outs{ s.all_logits ? nt : 1u };
      uint32_t const normed{ s.tap_ring ? nt : outs };
      {
        vec(nt - normed, normed, src, m.out_query, nullptr, { { 0, 0, m.out_norm, g.hidden } });
        if(s.tap_ring)
        {
          store_tap(g.hidden, 0, nt, static_cast<uint32_t>(ntaps - 1));
        }
        lin_params const p{ static_cast<uint32_t>(c.unpadded_vocab), h, outs, 2, c.logit_cap };
        uint32_t const tb{ outs > 1 ? 4u : 1u };
        use(tb == 4 ? b.linear4 : b.linear1, "unembed");
        [e setBytes:&p length:sizeof(p) atIndex:0];
        bind(1, weight(b, m.unembed, dtype::bf16));
        [e setBuffer:g.hidden offset:static_cast<NSUInteger>(normed - outs) * h * sizeof(float) atIndex:2];
        bind(3, g.logits);
        groups(p.rows, (outs + tb - 1) / tb, 1, 32);
      }
      auto const encoded{ std::chrono::steady_clock::now() };
      finish();
      if(profile)
      {
        std::vector<std::pair<std::string, std::pair<double, int>>> rows(profiled.begin(), profiled.end());
        std::sort(rows.begin(), rows.end(), [](auto const &x, auto const &y) { return x.second.first > y.second.first; });
        double total{};
        for(auto const &r : rows)
        {
          total += r.second.first;
        }
        std::fprintf(stderr, "GPU time per kernel, %d tokens at position %d: %.1f ms\n", tokens, s.pos, total * 1e3);
        for(auto const &r : rows)
        {
          std::fprintf(stderr, "  %-24s %8.2f ms  %4d dispatches  %6.1f us each\n", r.first.c_str(), r.second.first * 1e3,
                       r.second.second, r.second.first * 1e6 / r.second.second);
        }
      }
      else if(std::getenv("INK_GPU_TIMING"))
      {
        auto const done{ std::chrono::steady_clock::now() };
        std::fprintf(stderr, "forward of %d tokens: encode %.2f ms, GPU %.2f ms, total %.2f ms\n", tokens,
                     std::chrono::duration<double, std::milli>(encoded - started).count(),
                     (cmd.GPUEndTime - cmd.GPUStartTime) * 1e3,
                     std::chrono::duration<double, std::milli>(done - started).count());
      }

      auto const *const logits{ static_cast<float const *>(g.logits.contents) };
      size_t const v{ static_cast<size_t>(c.unpadded_vocab) };
      if(s.all_logits)
      {
        s.row_logits.insert(s.row_logits.end(), logits, logits + static_cast<size_t>(nt) * v);
      }
      s.logits.assign(logits + static_cast<size_t>(outs - 1) * v, logits + static_cast<size_t>(outs) * v);
      if(mine)
      {
        // The last token's row.
        auto const *const hidden{ static_cast<float const *>(g.hidden.contents) + static_cast<size_t>(normed - 1) * h };
        mine->hidden.assign(hidden, hidden + h);
        mine->logits = s.logits;
      }
      s.tokens.insert(s.tokens.end(), ids, ids + tokens);
      s.pos += tokens;
    }
  }
}

R"MSL(
// The forward pass as Metal compute kernels. Compiled at model open (see
// metal.mm), with TB (tokens per thread in `linear`) and NSG (simdgroups per
// head in `attention`) set per variant.
//
// Conventions: BF16 weights are read as ushort and widened; activations are
// FP32, rounded to BF16 where the CPU reference (cpu.cpp) rounds them. A
// "vector kernel" runs one threadgroup of 160 threads per token: thread i
// owns channels [16 i, 16 i + 16) of the 2304, and sums over all channels
// are reduced with simd_sum inside each simdgroup, then across the five
// simdgroups through threadgroup memory.
#include <metal_stdlib>
using namespace metal;

#ifndef GU_ROWS
#define GU_ROWS 4u
#endif
#ifndef DN_ROWS
#define DN_ROWS 4u
#endif
#ifndef TB
#define TB 1
#endif
#ifndef NSG
#define NSG 1
#endif

#define VSG 5
#define BL 16
#define BARRIER threadgroup_barrier(mem_flags::mem_threadgroup)

inline float bf16(ushort h)
{
  return as_type<float>(uint(h) << 16);
}

inline ushort to_bf16(float f)
{
  uint u = as_type<uint>(f);
  return ushort((u + 0x7fffu + ((u >> 16) & 1u)) >> 16);
}

inline float rbf(float f)
{
  return bf16(to_bf16(f));
}

// Four at a time: a GPU thread's time goes mostly to its loads, one after
// the other, so the kernels load vectors and keep each thread's work short.
inline float4 bf16v(ushort4 h)
{
  return as_type<float4>(uint4(h) << 16);
}

inline ushort4 to_bf16v(float4 f)
{
  uint4 u = as_type<uint4>(f);
  return ushort4((u + 0x7fffu + ((u >> 16) & 1u)) >> 16);
}

inline float4 rbfv(float4 f)
{
  return bf16v(to_bf16v(f));
}

inline float hsum(float4 a)
{
  return (a.x + a.y) + (a.z + a.w);
}

// E4M3 bytes to floats.
inline float4 e4m3v(uchar4 b)
{
  uint4 u = uint4(b);
  uint4 e = (u >> 3) & 15u;
  uint4 m = u & 7u;
  float4 normal = as_type<float4>(((e + 120u) << 23) | (m << 20));
  float4 mag = select(normal, float4(m) * 0x1p-9f, e == 0u);
  return select(mag, -mag, (u & 128u) != 0u);
}

inline float sigmoidf(float x)
{
  return 1.0f / (1.0f + exp(-x));
}

inline float softcap(float x, float cap)
{
  return cap > 0.0f ? cap * tanh(x / cap) : x;
}

static constant float E2M1[16] = { 0.0f,  0.5f,  1.0f,  1.5f,  2.0f,  3.0f,  4.0f,  6.0f,
                                   -0.0f, -0.5f, -1.0f, -1.5f, -2.0f, -3.0f, -4.0f, -6.0f };

// The four E2M1 values in the low 16 bits of u.
inline float4 e2m1v(uint u)
{
  // A table: decoding the bits arithmetically measured 2.6 times slower.
  uint4 n = (uint4(u) >> uint4(0u, 4u, 8u, 12u)) & 15u;
  return float4(E2M1[n.x], E2M1[n.y], E2M1[n.z], E2M1[n.w]);
}

// Nonnegative E4M3 rounding, nearest even.
inline float round_e4m3(float x)
{
  uint exponent = (as_type<uint>(x) >> 23) & 255u;
  float spacing = as_type<float>((max(exponent, 121u) - 3u) << 23);
  return rint(x / spacing) * spacing;
}

inline float round_e2m1(float x)
{
  float m = abs(x);
  float q = m > 0.25f ? 0.5f : 0.0f;
  if(m >= 0.75f) q = 1.0f;
  if(m > 1.25f) q = 1.5f;
  if(m >= 1.75f) q = 2.0f;
  if(m > 2.5f) q = 3.0f;
  if(m >= 3.5f) q = 4.0f;
  if(m > 5.0f) q = 6.0f;
  return x < 0.0f ? -q : q;
}

// NVFP4 4-over-6 quantization of a block of 16, given its row's maximum:
// writes the inner values (E2M1 times the E4M3 block scale).
inline void quantize_nvfp4_block(thread float *v, float row_max)
{
#pragma clang fp contract(off) reassociate(off)
  if(row_max == 0.0f)
  {
    for(uint i = 0; i < 16; ++i) v[i] = 0.0f;
    return;
  }
  float block_max = 0.0f;
  for(uint i = 0; i < 16; ++i) block_max = max(block_max, abs(v[i]));
  float normalizer = min(1536.0f / row_max, FLT_MAX);
  float decoder = 1.0f / normalizer;
  float outer = row_max * (1.0f / 1536.0f);
  float scale_a = round_e4m3(min(block_max * (normalizer * (1.0f / 6.0f)), 448.0f));
  float scale_b = round_e4m3(min(block_max * (normalizer * 0.25f), 448.0f));
  float inv_a = scale_a > 0.0f ? min(1.0f / (scale_a * decoder), FLT_MAX) : FLT_MAX;
  float inv_b = scale_b > 0.0f ? min(1.0f / (scale_b * decoder), FLT_MAX) : FLT_MAX;
  float ca[16], cb[16];
  float ea = 0.0f, eb = 0.0f;
  for(uint i = 0; i < 16; ++i)
  {
    ca[i] = round_e2m1(v[i] * inv_a) * scale_a;
    cb[i] = round_e2m1(v[i] * inv_b) * scale_b;
    ea += abs(v[i] - ca[i] * outer);
    eb += abs(v[i] - cb[i] * outer);
  }
  for(uint i = 0; i < 16; ++i) v[i] = eb < ea ? cb[i] : ca[i];
}

// MXFP8 quantization of 16 values of a block of 32 whose maximum is block_max.
inline void quantize_mxfp8_half(thread float *v, float block_max)
{
#pragma clang fp contract(off) reassociate(off)
  float raw = block_max * (1.0f / 448.0f);
  uint bits = as_type<uint>(raw);
  uint exponent = (bits >> 23) + ((bits & 0x7fffffu) != 0u ? 1u : 0u);
  exponent = min(exponent, 254u);
  const float minimum = 0x1p-127f;
  if(!(raw > minimum)) exponent = 0u;
  float scale = max(as_type<float>(exponent << 23), minimum);
  float inverse = exponent == 0u ? 0x1p127f : 1.0f / scale;
  for(uint i = 0; i < 16; ++i)
  {
    float x = clamp(v[i] * inverse, -448.0f, 448.0f);
    float r = round_e4m3(abs(x));
    v[i] = (x < 0.0f ? -r : r) * scale;
  }
}

// Embeddings: gather, RMS norm, round.

struct embed_params
{
  uint h;
  uint slot;
  uint tmax;
  float eps;
};

kernel void embed(constant embed_params &P [[buffer(0)]],
                  device const int *ids [[buffer(1)]],
                  device const ushort4 *table [[buffer(2)]],
                  device const ushort4 *norm [[buffer(3)]],
                  device float4 *stream [[buffer(4)]],
                  uint3 tg [[threadgroup_position_in_grid]],
                  ushort lane [[thread_index_in_simdgroup]],
                  ushort sg [[simdgroup_index_in_threadgroup]])
{
  threadgroup float red[VSG];
  uint tid = uint(sg) * 32u + lane;
  uint hq = P.h / 4u;
  uint q0 = min(tid * 4u, hq - 4u);
  bool active = tid * 4u < hq;
  uint t = tg.x;
  uint id = uint(ids[t]);
  float4 v[4];
  float ss = 0.0f;
  for(uint c = 0; c < 4; ++c)
  {
    v[c] = active ? bf16v(table[id * hq + q0 + c]) : float4(0.0f);
    ss += dot(v[c], v[c]);
  }
  float part = simd_sum(ss);
  if(lane == 0) red[sg] = part;
  BARRIER;
  float total = 0.0f;
  for(uint i = 0; i < VSG; ++i) total += red[i];
  float inv = rsqrt(total / float(P.h) + P.eps);
  if(active)
  {
    for(uint c = 0; c < 4; ++c)
    {
      stream[(P.slot * P.tmax + t) * hq + q0 + c] = rbfv(v[c] * inv * bf16v(norm[q0 + c]));
    }
  }
}

// A sublayer input. mix_norm: the mix of the residual sources (or the last
// source as is), RMS norm with a weight, round. When the visit has messages
// from the previous pass of the loop, the input goes through a controller
// first: mix_pair writes the mix and the message (stream slots tmp_in and
// tmp_msg) and their normalized pair; `linear` projects the pair down;
// `controller` gates the two; mix_norm then normalizes tmp_in.

struct vec_params
{
  uint t0;
  uint dst_t0;
  uint h;
  uint tmax;
  uint nsrc;
  uint src[6];
  uint has_query;
  uint query_row;
  uint nprev;
  uint prev[2];
  uint msg_row;
  uint tmp_in;
  uint tmp_msg;
  float eps;
};

// The mix of `n` sources by the query at `query + qoff`: softmax over the
// sources of (their RMS-normalized values . query) / sqrt(h), applied to the
// normalized values. `red` is the threadgroup's reduction scratch.
#define MIX(RESULT, N, SLOTS, QUERY, QOFF, RED)                                               \
  {                                                                                           \
    float4 x_[6][4];                                                                          \
    for(uint s_ = 0; s_ < N; ++s_)                                                            \
    {                                                                                         \
      float ss_ = 0.0f, dq_ = 0.0f;                                                           \
      for(uint c_ = 0; c_ < 4; ++c_)                                                          \
      {                                                                                       \
        float4 v_ = active ? stream[(SLOTS[s_] * P.tmax + t) * hq + q0 + c_] : float4(0.0f);  \
        x_[s_][c_] = v_;                                                                      \
        ss_ += dot(v_, v_);                                                                   \
        dq_ += dot(v_, QUERY[QOFF + q0 + c_]);                                                \
      }                                                                                       \
      float a_ = simd_sum(ss_);                                                               \
      float b_ = simd_sum(dq_);                                                               \
      if(lane == 0)                                                                           \
      {                                                                                       \
        RED[sg][2 * s_] = a_;                                                                 \
        RED[sg][2 * s_ + 1] = b_;                                                             \
      }                                                                                       \
    }                                                                                         \
    BARRIER;                                                                                  \
    float inv_[6], sc_[6];                                                                    \
    float best_ = -1e30f;                                                                     \
    for(uint s_ = 0; s_ < N; ++s_)                                                            \
    {                                                                                         \
      float ss_ = 0.0f, dq_ = 0.0f;                                                           \
      for(uint i_ = 0; i_ < VSG; ++i_)                                                        \
      {                                                                                       \
        ss_ += RED[i_][2 * s_];                                                               \
        dq_ += RED[i_][2 * s_ + 1];                                                           \
      }                                                                                       \
      inv_[s_] = rsqrt(ss_ / fh + 1e-6f);                                                     \
      sc_[s_] = dq_ * inv_[s_] * qscale;                                                      \
      best_ = max(best_, sc_[s_]);                                                            \
    }                                                                                         \
    float den_ = 0.0f;                                                                        \
    for(uint s_ = 0; s_ < N; ++s_)                                                            \
    {                                                                                         \
      sc_[s_] = exp(sc_[s_] - best_);                                                         \
      den_ += sc_[s_];                                                                        \
    }                                                                                         \
    for(uint c_ = 0; c_ < 4; ++c_) RESULT[c_] = float4(0.0f);                                 \
    for(uint s_ = 0; s_ < N; ++s_)                                                            \
    {                                                                                         \
      float w_ = sc_[s_] / den_ * inv_[s_];                                                   \
      for(uint c_ = 0; c_ < 4; ++c_) RESULT[c_] += w_ * x_[s_][c_];                           \
    }                                                                                         \
  }

kernel void mix_norm(constant vec_params &P [[buffer(0)]],
                     device const float4 *stream [[buffer(1)]],
                     device const float4 *query [[buffer(2)]],
                     device const ushort4 *norm [[buffer(7)]],
                     device float4 *dst [[buffer(8)]],
                     uint3 tg [[threadgroup_position_in_grid]],
                     ushort lane [[thread_index_in_simdgroup]],
                     ushort sg [[simdgroup_index_in_threadgroup]])
{
  threadgroup float rs[VSG][12];
  threadgroup float rn[VSG];
  uint tid = uint(sg) * 32u + lane;
  uint hq = P.h / 4u;
  uint q0 = min(tid * 4u, hq - 4u);
  bool active = tid * 4u < hq;
  uint t = P.t0 + tg.x;
  float fh = float(P.h);
  float qscale = 1.0f / sqrt(fh);
  float4 in[4];
  if(P.has_query != 0u)
  {
    MIX(in, P.nsrc, P.src, query, P.query_row * hq, rs)
  }
  else
  {
    for(uint c = 0; c < 4; ++c)
    {
      in[c] = active ? stream[(P.src[P.nsrc - 1u] * P.tmax + t) * hq + q0 + c] : float4(0.0f);
    }
  }
  float sn = 0.0f;
  for(uint c = 0; c < 4; ++c) sn += dot(in[c], in[c]);
  float part = simd_sum(sn);
  if(lane == 0) rn[sg] = part;
  BARRIER;
  float total = 0.0f;
  for(uint i = 0; i < VSG; ++i) total += rn[i];
  float inv = rsqrt(total / fh + P.eps);
  if(active)
  {
    uint row = P.dst_t0 + tg.x;
    for(uint c = 0; c < 4; ++c) dst[row * hq + q0 + c] = rbfv(in[c] * inv * bf16v(norm[q0 + c]));
  }
}

kernel void mix_pair(constant vec_params &P [[buffer(0)]],
                     device float4 *stream [[buffer(1)]],
                     device const float4 *query [[buffer(2)]],
                     device const float4 *mquery [[buffer(3)]],
                     device float4 *pair [[buffer(4)]],
                     uint3 tg [[threadgroup_position_in_grid]],
                     ushort lane [[thread_index_in_simdgroup]],
                     ushort sg [[simdgroup_index_in_threadgroup]])
{
  threadgroup float rs[VSG][12];
  threadgroup float rm[VSG][12];
  threadgroup float rc[VSG][2];
  uint tid = uint(sg) * 32u + lane;
  uint hq = P.h / 4u;
  uint q0 = min(tid * 4u, hq - 4u);
  bool active = tid * 4u < hq;
  uint t = P.t0 + tg.x;
  float fh = float(P.h);
  float qscale = 1.0f / sqrt(fh);
  float4 in[4];
  if(P.has_query != 0u)
  {
    MIX(in, P.nsrc, P.src, query, P.query_row * hq, rs)
  }
  else
  {
    for(uint c = 0; c < 4; ++c)
    {
      in[c] = active ? stream[(P.src[P.nsrc - 1u] * P.tmax + t) * hq + q0 + c] : float4(0.0f);
    }
  }
  float4 msg[4];
  MIX(msg, P.nprev, P.prev, mquery, P.msg_row * hq, rm)
  float si = 0.0f, sm = 0.0f;
  for(uint c = 0; c < 4; ++c)
  {
    si += dot(in[c], in[c]);
    sm += dot(msg[c], msg[c]);
  }
  float a = simd_sum(si);
  float b = simd_sum(sm);
  if(lane == 0)
  {
    rc[sg][0] = a;
    rc[sg][1] = b;
  }
  BARRIER;
  float ti = 0.0f, tm = 0.0f;
  for(uint i = 0; i < VSG; ++i)
  {
    ti += rc[i][0];
    tm += rc[i][1];
  }
  float ii = rsqrt(ti / fh + 1e-6f);
  float im = rsqrt(tm / fh + 1e-6f);
  if(active)
  {
    uint row = tg.x;
    for(uint c = 0; c < 4; ++c)
    {
      stream[(P.tmp_in * P.tmax + t) * hq + q0 + c] = in[c];
      stream[(P.tmp_msg * P.tmax + t) * hq + q0 + c] = msg[c];
      pair[row * 2u * hq + q0 + c] = rbfv(in[c] * ii);
      pair[row * 2u * hq + hq + q0 + c] = rbfv(msg[c] * im);
    }
  }
}

// The controller's gates, one thread per channel:
// in * (1 - tanh(forget . c)) + msg * tanh(gain . c).

struct ctl_params
{
  uint h;
  uint rank;
  uint tmax;
  uint tmp_in;
  uint tmp_msg;
};

kernel void controller(constant ctl_params &P [[buffer(0)]],
                       device const float4 *cmp [[buffer(1)]],
                       device const ushort4 *gain [[buffer(2)]],
                       device const ushort4 *forget [[buffer(3)]],
                       device float *stream [[buffer(4)]],
                       uint2 gid [[thread_position_in_grid]])
{
  uint c = gid.x, t = gid.y;
  uint n = P.rank / 4u;
  float4 g4 = float4(0.0f), f4 = float4(0.0f);
  for(uint j = 0; j < n; ++j)
  {
    float4 cv = cmp[t * n + j];
    g4 += bf16v(gain[c * n + j]) * cv;
    f4 += bf16v(forget[c * n + j]) * cv;
  }
  uint a = (P.tmp_in * P.tmax + t) * P.h + c;
  uint b = (P.tmp_msg * P.tmax + t) * P.h + c;
  stream[a] = stream[a] * (1.0f - tanh(hsum(f4))) + stream[b] * tanh(hsum(g4));
}

// y[t, r] = W[r, :] . x[t, :], W BF16 [rows, in], in a multiple of 8. A
// simdgroup computes one row for TB tokens. The lanes read the row interleaved,
// 8 weights (16 bytes) each at a time, so that a simdgroup's loads are 512
// contiguous bytes; each lane sums its share in the same order whatever TB is,
// so a token's result doesn't depend on how many tokens share the dispatch.

struct lin_params
{
  uint rows;
  uint in;
  uint nt;
  uint mode; // 0: as is, 1: round to BF16, 2: softcap
  float cap;
};

kernel void linear(constant lin_params &P [[buffer(0)]],
                   device const uint4 *w [[buffer(1)]],
                   device const float4 *x [[buffer(2)]],
                   device float *y [[buffer(3)]],
                   uint3 tg [[threadgroup_position_in_grid]],
                   ushort lane [[thread_index_in_simdgroup]])
{
  uint r = tg.x;
  uint t0 = tg.y * TB;
  uint n8 = P.in / 8u;
  float4 acc[TB];
  uint xo[TB];
  for(uint k = 0; k < TB; ++k)
  {
    acc[k] = float4(0.0f);
    xo[k] = min(t0 + k, P.nt - 1u) * (P.in / 4u);
  }
  uint wo = r * n8;
  for(uint i = lane; i < n8; i += 32u)
  {
    uint4 q = w[wo + i];
    float4 lo = float4(as_type<float>(q.x << 16), as_type<float>(q.x & 0xffff0000u),
                       as_type<float>(q.y << 16), as_type<float>(q.y & 0xffff0000u));
    float4 hi = float4(as_type<float>(q.z << 16), as_type<float>(q.z & 0xffff0000u),
                       as_type<float>(q.w << 16), as_type<float>(q.w & 0xffff0000u));
    for(uint k = 0; k < TB; ++k) acc[k] += lo * x[xo[k] + 2u * i] + hi * x[xo[k] + 2u * i + 1u];
  }
  for(uint k = 0; k < TB; ++k)
  {
    float s = simd_sum(hsum(acc[k]));
    if(lane == 0 && t0 + k < P.nt)
    {
      if(P.mode == 1u) s = rbf(s);
      if(P.mode == 2u) s = softcap(s, P.cap);
      y[(t0 + k) * P.rows + r] = s;
    }
  }
}

// Several matrices that read the same input, in one dispatch (fewer dispatches,
// and one larger read): up to 6, their rows one after the other, ends[i] the end
// of matrix i's. Each row is computed exactly as `linear` computes it.

struct multi_params
{
  uint in;
  uint nt;
  uint mode;
  float cap;
  uint count;
  uint ends[6];
};

kernel void linear_multi(constant multi_params &P [[buffer(0)]],
                         device const uint4 *w0 [[buffer(1)]],
                         device const uint4 *w1 [[buffer(2)]],
                         device const uint4 *w2 [[buffer(3)]],
                         device const uint4 *w3 [[buffer(4)]],
                         device const uint4 *w4 [[buffer(5)]],
                         device const uint4 *w5 [[buffer(6)]],
                         device const float4 *x [[buffer(7)]],
                         device float *y0 [[buffer(8)]],
                         device float *y1 [[buffer(9)]],
                         device float *y2 [[buffer(10)]],
                         device float *y3 [[buffer(11)]],
                         device float *y4 [[buffer(12)]],
                         device float *y5 [[buffer(13)]],
                         uint3 tg [[threadgroup_position_in_grid]],
                         ushort lane [[thread_index_in_simdgroup]])
{
  uint gr = tg.x;
  uint m = 0;
  while(m + 1u < P.count && gr >= P.ends[m]) ++m;
  uint start = m == 0u ? 0u : P.ends[m - 1u];
  uint rows = P.ends[m] - start;
  uint r = gr - start;
  device const uint4 *w = m == 0u ? w0 : m == 1u ? w1 : m == 2u ? w2 : m == 3u ? w3 : m == 4u ? w4 : w5;
  device float *y = m == 0u ? y0 : m == 1u ? y1 : m == 2u ? y2 : m == 3u ? y3 : m == 4u ? y4 : y5;
  uint t0 = tg.y * TB;
  uint n8 = P.in / 8u;
  float4 acc[TB];
  uint xo[TB];
  for(uint k = 0; k < TB; ++k)
  {
    acc[k] = float4(0.0f);
    xo[k] = min(t0 + k, P.nt - 1u) * (P.in / 4u);
  }
  uint wo = r * n8;
  for(uint i = lane; i < n8; i += 32u)
  {
    uint4 q = w[wo + i];
    float4 lo = float4(as_type<float>(q.x << 16), as_type<float>(q.x & 0xffff0000u),
                       as_type<float>(q.y << 16), as_type<float>(q.y & 0xffff0000u));
    float4 hi = float4(as_type<float>(q.z << 16), as_type<float>(q.z & 0xffff0000u),
                       as_type<float>(q.w << 16), as_type<float>(q.w & 0xffff0000u));
    for(uint k = 0; k < TB; ++k) acc[k] += lo * x[xo[k] + 2u * i] + hi * x[xo[k] + 2u * i + 1u];
  }
  for(uint k = 0; k < TB; ++k)
  {
    float s = simd_sum(hsum(acc[k]));
    if(lane == 0 && t0 + k < P.nt)
    {
      if(P.mode == 1u) s = rbf(s);
      if(P.mode == 2u) s = softcap(s, P.cap);
      y[(t0 + k) * rows + r] = s;
    }
  }
}

// The same for a batch, as a matrix product: a simdgroup computes 32 tokens
// by 32 rows with 8x8 matrices loaded straight from memory, which needs the
// weights as IEEE halves (`w`: a copy of the BF16 weights, rows padded to a
// multiple of 32; see metal.mm half_weight). in is a multiple of 8.
kernel void linear_mm(constant lin_params &P [[buffer(0)]],
                      device const half *w [[buffer(1)]],
                      device const float *x [[buffer(2)]],
                      device float *y [[buffer(3)]],
                      uint3 tg [[threadgroup_position_in_grid]],
                      ushort lane [[thread_index_in_simdgroup]])
{
  threadgroup float out[32 * 32];
  uint r0 = tg.x * 32u, t0 = tg.y * 32u;
  simdgroup_float8x8 mc[16];
  for(uint i = 0; i < 16; ++i) mc[i] = make_filled_simdgroup_matrix<float, 8>(0.0f);
  for(uint k = 0; k < P.in; k += 8u)
  {
    simdgroup_float8x8 mx[4];
    simdgroup_half8x8 mw[4];
    for(uint a = 0; a < 4; ++a) simdgroup_load(mx[a], x + (t0 + 8u * a) * P.in + k, P.in);
    for(uint b = 0; b < 4; ++b) simdgroup_load(mw[b], w + (r0 + 8u * b) * P.in + k, P.in, 0, true);
    for(uint a = 0; a < 4; ++a)
    {
      for(uint b = 0; b < 4; ++b) simdgroup_multiply_accumulate(mc[a * 4 + b], mx[a], mw[b], mc[a * 4 + b]);
    }
  }
  for(uint a = 0; a < 4; ++a)
  {
    for(uint b = 0; b < 4; ++b) simdgroup_store(mc[a * 4 + b], out + (8u * a) * 32u + 8u * b, 32);
  }
  BARRIER;
  uint t = t0 + lane;
  if(t < P.nt)
  {
    for(uint j = 0; j < 32; ++j)
    {
      if(r0 + j < P.rows)
      {
        float s = out[uint(lane) * 32u + j];
        if(P.mode == 1u) s = rbf(s);
        if(P.mode == 2u) s = softcap(s, P.cap);
        y[t * P.rows + r0 + j] = s;
      }
    }
  }
}

// Short causal convolutions over time. One thread per channel: it owns the
// channel's history and walks the chunk's tokens in order.

struct conv_params
{
  uint ch;
  uint nt;
  uint mode; // 0: out; 1: stream[dst] = out; 2: stream[dst] += out; 3: stream[dst] = round(stream[dst] + out)
  uint dst;
  uint tmax;
  uint h;
  uint heads;
  float norm;
  uint keep; // 1: each token's input also into `kept` (a draft's check, to roll back)
};

kernel void conv_fixed(constant conv_params &P [[buffer(0)]],
                       device const ushort *w [[buffer(1)]],
                       device const float *in [[buffer(2)]],
                       device float *hist [[buffer(3)]],
                       device float *out [[buffer(4)]],
                       device float *stream [[buffer(5)]],
                       device float *kept [[buffer(6)]],
                       uint c [[thread_position_in_grid]])
{
  if(c >= P.ch) return;
  float h0 = hist[c], h1 = hist[P.ch + c], h2 = hist[2u * P.ch + c];
  float w0 = bf16(w[c * 4u]), w1 = bf16(w[c * 4u + 1u]), w2 = bf16(w[c * 4u + 2u]), w3 = bf16(w[c * 4u + 3u]);
  for(uint t = 0; t < P.nt; ++t)
  {
    float x = in[t * P.ch + c];
    if(P.keep != 0u) kept[t * P.ch + c] = x;
    float sum = x;
    sum += w0 * h0;
    sum += w1 * h1;
    sum += w2 * h2;
    sum += w3 * x;
    float o = rbf(sum * P.norm);
    uint at = (P.dst * P.tmax + t) * P.h + c;
    if(P.mode == 0u) out[t * P.ch + c] = o;
    else if(P.mode == 1u) stream[at] = o;
    else if(P.mode == 2u) stream[at] = stream[at] + o;
    else stream[at] = rbf(stream[at] + o);
    h0 = h1;
    h1 = h2;
    h2 = x;
  }
  hist[c] = h0;
  hist[P.ch + c] = h1;
  hist[2u * P.ch + c] = h2;
}

// Projected taps: static_w [4, ch] plus per-token taps [T, heads * 4],
// indexed by lag (tap 0 is the current token).
kernel void conv_dyn(constant conv_params &P [[buffer(0)]],
                     device const ushort *stat [[buffer(1)]],
                     device const float *dyn [[buffer(2)]],
                     device const float *in [[buffer(3)]],
                     device float *hist [[buffer(4)]],
                     device float *out [[buffer(5)]],
                     device float *kept [[buffer(6)]],
                     uint c [[thread_position_in_grid]])
{
  if(c >= P.ch) return;
  float h0 = hist[c], h1 = hist[P.ch + c], h2 = hist[2u * P.ch + c];
  float s0 = bf16(stat[c]), s1 = bf16(stat[P.ch + c]), s2 = bf16(stat[2u * P.ch + c]), s3 = bf16(stat[3u * P.ch + c]);
  uint head = c / (P.ch / P.heads);
  for(uint t = 0; t < P.nt; ++t)
  {
    float x = in[t * P.ch + c];
    if(P.keep != 0u) kept[t * P.ch + c] = x;
    uint d = (t * P.heads + head) * 4u;
    float sum = x;
    sum += (s0 + dyn[d]) * x;
    sum += (s1 + dyn[d + 1u]) * h2;
    sum += (s2 + dyn[d + 2u]) * h1;
    sum += (s3 + dyn[d + 3u]) * h0;
    out[t * P.ch + c] = rbf(sum * P.norm);
    h0 = h1;
    h1 = h2;
    h2 = x;
  }
  hist[c] = h0;
  hist[P.ch + c] = h1;
  hist[2u * P.ch + c] = h2;
}

// Hidden states kept for a draft model: rows of `src` (BF16-rounded floats,
// `stride` apart) into the session's ring, as BF16 bits, at position p0 + t.

struct tap_params
{
  uint h;
  uint p0;
  uint slots;
  uint ntaps;
  uint tap;
  uint src_row; // first row of src
};

kernel void tap_store(constant tap_params &P [[buffer(0)]],
                      device const float *src [[buffer(1)]],
                      device ushort *ring [[buffer(2)]],
                      uint2 at [[thread_position_in_grid]])
{
  uint c = at.x, t = at.y;
  if(c >= P.h) return;
  uint slot = (P.p0 + t) % P.slots;
  ring[(slot * P.ntaps + P.tap) * P.h + c] = ushort(as_type<uint>(src[(P.src_row + t) * P.h + c]) >> 16);
}

// Keys (L2-clipped) and values (RMS-normalized) into the visit's cache, as
// halves holding the BF16-rounded values. A
// simdgroup per (kv head, token, keys or values); a lane has 4 of the 128.

struct kvs_params
{
  uint p0;
  uint slots;
  uint kvh;
  float clip;
  float eps;
};

kernel void kv_store(constant kvs_params &P [[buffer(0)]],
                     device const float4 *kc [[buffer(1)]],
                     device const float4 *vc [[buffer(2)]],
                     device half4 *K [[buffer(3)]],
                     device half4 *V [[buffer(4)]],
                     uint3 tg [[threadgroup_position_in_grid]],
                     ushort lane [[thread_index_in_simdgroup]])
{
  uint g = tg.x, t = tg.y;
  uint slot = (P.p0 + t) % P.slots;
  uint src = (t * P.kvh + g) * 32u + lane;
  uint dst = (slot * P.kvh + g) * 32u + lane;
  if(tg.z == 0u)
  {
    float4 v = kc[src];
    float ss = simd_sum(dot(v, v));
    K[dst] = half4(rbfv(v * min(P.clip / (sqrt(ss) + 1e-6f), 1.0f)));
  }
  else
  {
    float4 v = vc[src];
    float ss = simd_sum(dot(v, v));
    V[dst] = half4(rbfv(v * rsqrt(ss / 128.0f + P.eps)));
  }
}

// Queries and relative-position features: scale, L2 clip, temperature,
// round. A simdgroup per (head, token).

struct qp_params
{
  uint p0;
  uint heads;
  uint kvh;
  uint tmax;
  uint global;
  float qclip;
  float rclip;
  float log_floor;
  float log_alpha;
};

kernel void q_prep(constant qp_params &P [[buffer(0)]],
                   device float4 *q [[buffer(1)]],
                   device float4 *r [[buffer(2)]],
                   device const ushort4 *qscale [[buffer(3)]],
                   device const ushort4 *rscale [[buffer(4)]],
                   device float4 *qg [[buffer(5)]],
                   uint3 tg [[threadgroup_position_in_grid]],
                   ushort lane [[thread_index_in_simdgroup]])
{
  uint head = tg.x, t = tg.y;
  float tau = 1.0f;
  if(P.global != 0u && P.log_floor > 0.0f && P.log_alpha != 0.0f)
  {
    tau = 1.0f + P.log_alpha * log(max(float(P.p0 + t + 1u) / P.log_floor, 1.0f));
  }
  uint qa = (t * P.heads + head) * 32u + lane;
  float4 qv = q[qa] * bf16v(qscale[head * 32u + lane]);
  float qs = simd_sum(dot(qv, qv));
  qv = rbfv(qv * (min(P.qclip / (sqrt(qs) + 1e-6f), 1.0f) * tau));
  q[qa] = qv;
  // The same by key-value group, for the batched attention: [group, token,
  // head in group, 128].
  uint per = P.heads / P.kvh;
  qg[(((head / per) * P.tmax + t) * per + head % per) * 32u + lane] = qv;
  bool has_r = lane < 4;
  uint ra = (t * P.heads + head) * 4u + min(uint(lane), 3u);
  float4 rv = has_r ? r[ra] * bf16v(rscale[head * 4u + min(uint(lane), 3u)]) : float4(0.0f);
  float rs = simd_sum(dot(rv, rv));
  if(has_r) r[ra] = rbfv(rv * (min(P.rclip / (sqrt(rs) + 1e-6f), 1.0f) * tau));
}

// Attention of one head of one token: a threadgroup of 32 NSG threads, each
// taking every (32 NSG)-th key with a running softmax (max, sum, weighted
// values), merged at the end. The sink is one more logit with a zero value.
// `rel` is the relative-position projection transposed: [extent, 16] F32.

struct att_params
{
  uint p0;
  uint heads;
  uint kvh;
  uint slots;
  uint window;
  uint extent;
  float scale;
};

kernel void attention(constant att_params &P [[buffer(0)]],
                      device const float4 *q [[buffer(1)]],
                      device const float4 *r [[buffer(2)]],
                      device const float *sink [[buffer(3)]],
                      device const float4 *gate [[buffer(4)]],
                      device const float4 *rel [[buffer(5)]],
                      device const half4 *K [[buffer(6)]],
                      device const half4 *V [[buffer(7)]],
                      device float4 *out [[buffer(8)]],
                      uint3 tg [[threadgroup_position_in_grid]],
                      ushort lane [[thread_index_in_simdgroup]],
                      ushort sg [[simdgroup_index_in_threadgroup]])
{
#if NSG > 1
  threadgroup float tmax_[NSG];
  threadgroup float tsum[NSG];
  threadgroup float4 tacc[NSG][32];
#endif
  uint head = tg.x, t = tg.y;
  uint p = P.p0 + t;
  uint first = (P.window > 0u && p + 1u > P.window) ? p + 1u - P.window : 0u;
  uint g = head / (P.heads / P.kvh);
  uint tid = uint(sg) * 32u + lane;
  const uint nth = 32u * NSG;

  float4 qv[32];
  for(uint i = 0; i < 32; ++i) qv[i] = q[(t * P.heads + head) * 32u + i];
  float4 rv[4];
  for(uint i = 0; i < 4; ++i) rv[i] = r[(t * P.heads + head) * 4u + i];

  float m = -1e30f, l = 0.0f;
  float4 acc[32];
  for(uint i = 0; i < 32; ++i) acc[i] = float4(0.0f);
  for(uint j = first + tid; j <= p; j += nth)
  {
    uint at = ((j % P.slots) * P.kvh + g) * 32u;
    float4 d4 = float4(0.0f);
    for(uint i = 0; i < 32; ++i) d4 += qv[i] * float4(K[at + i]);
    uint dist = p - j;
    float b = 0.0f;
    if(dist < P.extent)
    {
      float4 b4 = float4(0.0f);
      for(uint i = 0; i < 4; ++i) b4 += rv[i] * rel[dist * 4u + i];
      b = rbf(hsum(b4));
    }
    float s = hsum(d4) * P.scale + b;
    if(s > m)
    {
      float f = exp(m - s);
      l *= f;
      for(uint i = 0; i < 32; ++i) acc[i] *= f;
      m = s;
    }
    float pr = exp(s - m);
    l += pr;
    for(uint i = 0; i < 32; ++i) acc[i] += pr * float4(V[at + i]);
  }

  float sk = sink[t * P.heads + head];
  float best = simd_max(m);
#if NSG > 1
  if(lane == 0) tmax_[sg] = best;
  BARRIER;
  best = sk;
  for(uint i = 0; i < NSG; ++i) best = max(best, tmax_[i]);
#else
  best = max(best, sk);
#endif
  float f = exp(m - best);
  float total = simd_sum(l * f);
  uint base = (t * P.heads + head) * 32u;
#if NSG > 1
  if(lane == 0) tsum[sg] = total;
  for(uint i = 0; i < 32; ++i)
  {
    float4 a = simd_sum(acc[i] * f);
    if(lane == 0) tacc[sg][i] = a;
  }
  BARRIER;
  if(sg == 0)
  {
    float den = exp(sk - best);
    for(uint i = 0; i < NSG; ++i) den += tsum[i];
    float4 a = float4(0.0f);
    for(uint k = 0; k < NSG; ++k) a += tacc[k][lane];
    out[base + lane] = rbfv(a / den / (1.0f + exp(-gate[base + lane])));
  }
#else
  float den = total + exp(sk - best);
  for(uint i = 0; i < 32; ++i)
  {
    float4 a = simd_sum(acc[i] * f);
    if(lane == 0) out[base + i] = rbfv(a / den / (1.0f + exp(-gate[base + i])));
  }
#endif
}

// Attention of one token over a long context, split across the keys (as
// flash-decoding does): a threadgroup of NSG simdgroups takes a chunk of the
// keys for the query heads that share one key-value head, so that each key and
// value row is read once for all of them. A simdgroup takes one key at a time,
// its lanes splitting the head's 128 values four each (the rows are read in one
// coalesced pass), with a running softmax per head. Each chunk leaves, per head,
// its max, its sum and its weighted values; att_merge combines the chunks with
// the sink and the gate. The same arithmetic as `attention`, in another order.
// Only for one token (p0 is its position) and a global layer (no window).

#define SPLIT_HEADS 4

struct split_params
{
  uint p0;
  uint heads;
  uint kvh;
  uint slots;
  uint extent;
  uint chunk;
  uint splits;
  float scale;
};

kernel void att_split(constant split_params &P [[buffer(0)]],
                      device const float4 *q [[buffer(1)]],
                      device const float4 *r [[buffer(2)]],
                      device const float4 *rel [[buffer(3)]],
                      device const half4 *K [[buffer(4)]],
                      device const half4 *V [[buffer(5)]],
                      device float4 *part [[buffer(6)]],
                      uint3 tg [[threadgroup_position_in_grid]],
                      ushort lane [[thread_index_in_simdgroup]],
                      ushort sg [[simdgroup_index_in_threadgroup]])
{
  threadgroup float tm[NSG][SPLIT_HEADS];
  threadgroup float tl[NSG][SPLIT_HEADS];
  threadgroup float4 tacc[NSG][SPLIT_HEADS][32];
  uint g = tg.x, split = tg.y;
  uint per = P.heads / P.kvh;
  uint p = P.p0;
  uint begin = split * P.chunk;
  uint end = min(begin + P.chunk, p + 1u);

  float4 qv[SPLIT_HEADS];
  float4 rv[SPLIT_HEADS];
  float m[SPLIT_HEADS], l[SPLIT_HEADS];
  float4 acc[SPLIT_HEADS];
  for(uint h = 0; h < per; ++h)
  {
    uint head = g * per + h;
    qv[h] = q[head * 32u + lane];
    rv[h] = lane < 4 ? r[head * 4u + lane] : float4(0.0f);
    m[h] = -1e30f;
    l[h] = 0.0f;
    acc[h] = float4(0.0f);
  }

  for(uint j = begin + sg; j < end; j += NSG)
  {
    uint at = ((j % P.slots) * P.kvh + g) * 32u;
    float4 k = float4(K[at + lane]);
    float4 v = float4(V[at + lane]);
    uint dist = p - j;
    bool near = dist < P.extent;
    float4 rl = (near && lane < 4) ? rel[dist * 4u + lane] : float4(0.0f);
    for(uint h = 0; h < per; ++h)
    {
      float s = simd_sum(dot(qv[h], k)) * P.scale;
      if(near) s += rbf(simd_sum(dot(rv[h], rl)));
      if(s > m[h])
      {
        float f = exp(m[h] - s);
        l[h] *= f;
        acc[h] *= f;
        m[h] = s;
      }
      float pr = exp(s - m[h]);
      l[h] += pr;
      acc[h] += pr * v;
    }
  }

  for(uint h = 0; h < per; ++h)
  {
    if(lane == 0)
    {
      tm[sg][h] = m[h];
      tl[sg][h] = l[h];
    }
    tacc[sg][h][lane] = acc[h];
  }
  BARRIER;
  if(sg == 0)
  {
    for(uint h = 0; h < per; ++h)
    {
      float best = -1e30f;
      for(uint i = 0; i < NSG; ++i) best = max(best, tm[i][h]);
      float sum = 0.0f;
      float4 a = float4(0.0f);
      for(uint i = 0; i < NSG; ++i)
      {
        float f = exp(tm[i][h] - best);
        sum += tl[i][h] * f;
        a += tacc[i][h][lane] * f;
      }
      // A record a head a chunk: 32 values, then (max, sum).
      uint base = (split * P.heads + g * per + h) * 33u;
      part[base + lane] = a;
      if(lane == 0) part[base + 32u] = float4(best, sum, 0.0f, 0.0f);
    }
  }
}

// The chunks of att_split combined, a simdgroup a head: the sink is one more
// logit with a zero value, and the output is gated and rounded as `attention`'s.
kernel void att_merge(constant split_params &P [[buffer(0)]],
                      device const float4 *part [[buffer(1)]],
                      device const float *sink [[buffer(2)]],
                      device const float4 *gate [[buffer(3)]],
                      device float4 *out [[buffer(4)]],
                      uint3 tg [[threadgroup_position_in_grid]],
                      ushort lane [[thread_index_in_simdgroup]])
{
  uint head = tg.x;
  float sk = sink[head];
  float best = sk;
  for(uint s = 0; s < P.splits; ++s) best = max(best, part[(s * P.heads + head) * 33u + 32u].x);
  float den = exp(sk - best);
  float4 a = float4(0.0f);
  for(uint s = 0; s < P.splits; ++s)
  {
    uint base = (s * P.heads + head) * 33u;
    float4 ml = part[base + 32u];
    float f = exp(ml.x - best);
    den += ml.y * f;
    a += part[base + lane] * f;
  }
  uint o = head * 32u + lane;
  out[o] = rbfv(a / den / (1.0f + exp(-gate[o])));
}

// Attention for a few tokens (up to 16: one decoded, or a draft's check), the
// keys split in chunks as att_split does, for any layer (global or with a
// window). A token's chunks depend only on how many keys it sees (rows_chunk),
// so a token's result is the same bits whether it is alone or among others.
// Grid: (key-value head, chunk, token); a chunk past a token's last does
// nothing. att_rows_merge then combines a token's chunks, a simdgroup a head.

struct rows_params
{
  uint p0;
  uint heads;
  uint kvh;
  uint slots;
  uint window;
  uint extent;
  uint most; // chunks a token at most (the scratch's stride)
  float scale;
};

// Keys a chunk, by the keys a token sees: 256, or more past 16,384 keys, so
// that there are never more than 64 chunks.
inline uint rows_chunk(uint keys)
{
  uint c = (keys + 63u) / 64u;
  return max(256u, (c + 63u) / 64u * 64u);
}

inline uint rows_first(uint p, uint window)
{
  return (window > 0u && p + 1u > window) ? p + 1u - window : 0u;
}

kernel void att_rows(constant rows_params &P [[buffer(0)]],
                     device const float4 *q [[buffer(1)]],
                     device const float4 *r [[buffer(2)]],
                     device const float4 *rel [[buffer(3)]],
                     device const half4 *K [[buffer(4)]],
                     device const half4 *V [[buffer(5)]],
                     device float4 *part [[buffer(6)]],
                     uint3 tg [[threadgroup_position_in_grid]],
                     ushort lane [[thread_index_in_simdgroup]],
                     ushort sg [[simdgroup_index_in_threadgroup]])
{
  threadgroup float tm[NSG][SPLIT_HEADS];
  threadgroup float tl[NSG][SPLIT_HEADS];
  threadgroup float4 tacc[NSG][SPLIT_HEADS][32];
  uint g = tg.x, split = tg.y, t = tg.z;
  uint per = P.heads / P.kvh;
  uint p = P.p0 + t;
  uint first = rows_first(p, P.window);
  uint keys = p + 1u - first;
  uint chunk = rows_chunk(keys);
  if(split * chunk >= keys) return;
  uint begin = first + split * chunk;
  uint end = min(begin + chunk, p + 1u);

  float4 qv[SPLIT_HEADS];
  float4 rv[SPLIT_HEADS];
  float m[SPLIT_HEADS], l[SPLIT_HEADS];
  float4 acc[SPLIT_HEADS];
  for(uint h = 0; h < per; ++h)
  {
    uint head = g * per + h;
    qv[h] = q[(t * P.heads + head) * 32u + lane];
    rv[h] = lane < 4 ? r[(t * P.heads + head) * 4u + lane] : float4(0.0f);
    m[h] = -1e30f;
    l[h] = 0.0f;
    acc[h] = float4(0.0f);
  }

  for(uint j = begin + sg; j < end; j += NSG)
  {
    uint at = ((j % P.slots) * P.kvh + g) * 32u;
    float4 k = float4(K[at + lane]);
    float4 v = float4(V[at + lane]);
    uint dist = p - j;
    bool near = dist < P.extent;
    float4 rl = (near && lane < 4) ? rel[dist * 4u + lane] : float4(0.0f);
    for(uint h = 0; h < per; ++h)
    {
      float s = simd_sum(dot(qv[h], k)) * P.scale;
      if(near) s += rbf(simd_sum(dot(rv[h], rl)));
      if(s > m[h])
      {
        float f = exp(m[h] - s);
        l[h] *= f;
        acc[h] *= f;
        m[h] = s;
      }
      float pr = exp(s - m[h]);
      l[h] += pr;
      acc[h] += pr * v;
    }
  }

  for(uint h = 0; h < per; ++h)
  {
    if(lane == 0)
    {
      tm[sg][h] = m[h];
      tl[sg][h] = l[h];
    }
    tacc[sg][h][lane] = acc[h];
  }
  BARRIER;
  if(sg == 0)
  {
    for(uint h = 0; h < per; ++h)
    {
      float best = -1e30f;
      for(uint i = 0; i < NSG; ++i) best = max(best, tm[i][h]);
      float sum = 0.0f;
      float4 a = float4(0.0f);
      for(uint i = 0; i < NSG; ++i)
      {
        float f = exp(tm[i][h] - best);
        sum += tl[i][h] * f;
        a += tacc[i][h][lane] * f;
      }
      uint base = ((t * P.most + split) * P.heads + g * per + h) * 33u;
      part[base + lane] = a;
      if(lane == 0) part[base + 32u] = float4(best, sum, 0.0f, 0.0f);
    }
  }
}

kernel void att_rows_merge(constant rows_params &P [[buffer(0)]],
                           device const float4 *part [[buffer(1)]],
                           device const float *sink [[buffer(2)]],
                           device const float4 *gate [[buffer(3)]],
                           device float4 *out [[buffer(4)]],
                           uint3 tg [[threadgroup_position_in_grid]],
                           ushort lane [[thread_index_in_simdgroup]])
{
  uint head = tg.x, t = tg.y;
  uint p = P.p0 + t;
  uint first = rows_first(p, P.window);
  uint keys = p + 1u - first;
  uint chunk = rows_chunk(keys);
  uint splits = (keys + chunk - 1u) / chunk;
  float sk = sink[t * P.heads + head];
  float best = sk;
  for(uint s = 0; s < splits; ++s) best = max(best, part[((t * P.most + s) * P.heads + head) * 33u + 32u].x);
  float den = exp(sk - best);
  float4 a = float4(0.0f);
  for(uint s = 0; s < splits; ++s)
  {
    uint base = ((t * P.most + s) * P.heads + head) * 33u;
    float4 ml = part[base + 32u];
    float f = exp(ml.x - best);
    den += ml.y * f;
    a += part[base + lane] * f;
  }
  uint o = (t * P.heads + head) * 32u + lane;
  out[o] = rbfv(a / den / (1.0f + exp(-gate[o])));
}

// Attention for a batch, as matrix products. Per key-value group g, with
// rows = (token, head of g):
//   att_scores:  scores[row, slot] = q[row] . k[slot] / sqrt(128) + bias, for
//                every slot of the cache, -1e30 where the slot's position is
//                outside the token's window (or after it);
//   att_softmax: scores -> exp(scores - max), and 1 / (their sum + the sink's);
//   att_pv:      out[row] = (scores[row] . v) * that * sigmoid(gate), rounded.
// rel_bias first gives every (token, head, distance)'s relative-position
// bias. t0 and tn are a sub-batch of the chunk's tokens (the scores of a
// long context don't fit for all of them at once); rows is the scratch's
// rows per group, nkp the slots covered; both multiples of 32.

struct rb_params
{
  uint heads;
  uint extent;
};

kernel void rel_bias(constant rb_params &P [[buffer(0)]],
                     device const float4 *r [[buffer(1)]],
                     device const float4 *rel [[buffer(2)]],
                     device float *bias [[buffer(3)]],
                     uint3 gid [[thread_position_in_grid]])
{
  uint dist = gid.x, head = gid.y, t = gid.z;
  float4 b4 = float4(0.0f);
  for(uint i = 0; i < 4; ++i) b4 += r[(t * P.heads + head) * 4u + i] * rel[dist * 4u + i];
  bias[(t * P.heads + head) * P.extent + dist] = rbf(hsum(b4));
}

struct ab_params
{
  uint p0;
  uint nt;
  uint t0;
  uint tn;
  uint heads;
  uint kvh;
  uint slots;
  uint window;
  uint extent;
  uint nkp;
  uint rows;
  uint tmax;
  float scale;
};

kernel void att_scores(constant ab_params &P [[buffer(0)]],
                       device const float *qg [[buffer(1)]],
                       device const half *K [[buffer(2)]],
                       device const float *bias [[buffer(3)]],
                       device float *scores [[buffer(4)]],
                       uint3 tg [[threadgroup_position_in_grid]],
                       ushort lane [[thread_index_in_simdgroup]])
{
  threadgroup float out[32 * 32];
  uint s0 = tg.x * 32u, rr0 = tg.y * 32u, g = tg.z;
  uint per = P.heads / P.kvh;
  uint stride = P.kvh * 128u;
  simdgroup_float8x8 mc[16];
  for(uint i = 0; i < 16; ++i) mc[i] = make_filled_simdgroup_matrix<float, 8>(0.0f);
  for(uint d = 0; d < 128u; d += 8u)
  {
    simdgroup_float8x8 mq[4];
    simdgroup_half8x8 mk[4];
    for(uint a = 0; a < 4; ++a)
    {
      simdgroup_load(mq[a], qg + ((g * P.tmax + P.t0) * per + rr0 + 8u * a) * 128u + d, 128);
    }
    for(uint b = 0; b < 4; ++b) simdgroup_load(mk[b], K + ((s0 + 8u * b) * P.kvh + g) * 128u + d, stride, 0, true);
    for(uint a = 0; a < 4; ++a)
    {
      for(uint b = 0; b < 4; ++b) simdgroup_multiply_accumulate(mc[a * 4 + b], mq[a], mk[b], mc[a * 4 + b]);
    }
  }
  for(uint a = 0; a < 4; ++a)
  {
    for(uint b = 0; b < 4; ++b) simdgroup_store(mc[a * 4 + b], out + (8u * a) * 32u + 8u * b, 32);
  }
  BARRIER;
  uint row = rr0 + lane;
  uint tl = row / per;
  if(tl < P.tn)
  {
    uint t = P.t0 + tl;
    uint head = g * per + row % per;
    uint p = P.p0 + t;
    uint last = P.p0 + P.nt - 1u;
    uint first = (P.window > 0u && p + 1u > P.window) ? p + 1u - P.window : 0u;
    for(uint j = 0; j < 32; ++j)
    {
      uint slot = s0 + j;
      float s = -1e30f;
      if(slot < P.slots)
      {
        // The slot holds the latest position congruent to it.
        uint back = (last + P.slots - slot) % P.slots;
        if(back <= last)
        {
          uint pos = last - back;
          if(pos >= first && pos <= p)
          {
            uint dist = p - pos;
            s = out[uint(lane) * 32u + j] * P.scale
                + (dist < P.extent ? bias[(t * P.heads + head) * P.extent + dist] : 0.0f);
          }
        }
      }
      scores[(g * P.rows + row) * P.nkp + slot] = s;
    }
  }
}

kernel void att_softmax(constant ab_params &P [[buffer(0)]],
                        device float4 *scores [[buffer(1)]],
                        device const float *sink [[buffer(2)]],
                        device float *inv [[buffer(3)]],
                        uint3 tg [[threadgroup_position_in_grid]],
                        ushort lane [[thread_index_in_simdgroup]],
                        ushort sg [[simdgroup_index_in_threadgroup]])
{
  threadgroup float tm[4];
  threadgroup float ts[4];
  uint head = tg.x, tl = tg.y;
  uint per = P.heads / P.kvh;
  uint t = P.t0 + tl;
  uint base = (((head / per) * P.rows + tl * per + head % per) * P.nkp) / 4u;
  uint n4 = P.nkp / 4u;
  uint tid = uint(sg) * 32u + lane;
  float m = -1e30f;
  for(uint i = tid; i < n4; i += 128u)
  {
    float4 v = scores[base + i];
    m = max(m, max(max(v.x, v.y), max(v.z, v.w)));
  }
  float mm = simd_max(m);
  if(lane == 0) tm[sg] = mm;
  BARRIER;
  float sk = sink[t * P.heads + head];
  float best = max(max(sk, tm[0]), max(tm[1], max(tm[2], tm[3])));
  float l = 0.0f;
  for(uint i = tid; i < n4; i += 128u)
  {
    float4 e = exp(scores[base + i] - best);
    scores[base + i] = e;
    l += hsum(e);
  }
  float ls = simd_sum(l);
  if(lane == 0) ts[sg] = ls;
  BARRIER;
  if(tid == 0u) inv[t * P.heads + head] = 1.0f / (ts[0] + ts[1] + ts[2] + ts[3] + exp(sk - best));
}

kernel void att_pv(constant ab_params &P [[buffer(0)]],
                   device const float *scores [[buffer(1)]],
                   device const half *V [[buffer(2)]],
                   device const float *inv [[buffer(3)]],
                   device const float *gate [[buffer(4)]],
                   device float *attended [[buffer(5)]],
                   uint3 tg [[threadgroup_position_in_grid]],
                   ushort lane [[thread_index_in_simdgroup]])
{
  threadgroup float out[32 * 32];
  uint d0 = tg.x * 32u, rr0 = tg.y * 32u, g = tg.z;
  uint per = P.heads / P.kvh;
  uint stride = P.kvh * 128u;
  simdgroup_float8x8 mc[16];
  for(uint i = 0; i < 16; ++i) mc[i] = make_filled_simdgroup_matrix<float, 8>(0.0f);
  for(uint k = 0; k < P.nkp; k += 8u)
  {
    simdgroup_float8x8 mp[4];
    simdgroup_half8x8 mv[4];
    for(uint a = 0; a < 4; ++a) simdgroup_load(mp[a], scores + (g * P.rows + rr0 + 8u * a) * P.nkp + k, P.nkp);
    for(uint b = 0; b < 4; ++b) simdgroup_load(mv[b], V + (k * P.kvh + g) * 128u + d0 + 8u * b, stride);
    for(uint a = 0; a < 4; ++a)
    {
      for(uint b = 0; b < 4; ++b) simdgroup_multiply_accumulate(mc[a * 4 + b], mp[a], mv[b], mc[a * 4 + b]);
    }
  }
  for(uint a = 0; a < 4; ++a)
  {
    for(uint b = 0; b < 4; ++b) simdgroup_store(mc[a * 4 + b], out + (8u * a) * 32u + 8u * b, 32);
  }
  BARRIER;
  uint row = rr0 + lane;
  uint tl = row / per;
  if(tl < P.tn)
  {
    uint t = P.t0 + tl;
    uint head = g * per + row % per;
    float iv = inv[t * P.heads + head];
    for(uint j = 0; j < 32; ++j)
    {
      uint at = (t * P.heads + head) * 128u + d0 + j;
      attended[at] = rbf(out[uint(lane) * 32u + j] * iv * sigmoidf(gate[at]));
    }
  }
}

// Routing, from the router's logits (`linear`): the top experts by
// sigmoid(logit) + bias and their weights, and the experts' input quantized
// as the checkpoint requires. A threadgroup per token: thread e ranks expert
// e, and every thread quantizes its 16 channels.

struct route_params
{
  uint h;
  uint ne;
  uint topk;
  uint mode; // 0: FP32 input, 1: NVFP4, 2: MXFP8
  uint has_bias;
  float route_scale;
};

kernel void route(constant route_params &P [[buffer(0)]],
                  device const float4 *x [[buffer(1)]],
                  device const float *lg [[buffer(2)]],
                  device const float *bias [[buffer(3)]],
                  device float4 *xq [[buffer(4)]],
                  device float *xmax [[buffer(5)]],
                  device uint *chosen [[buffer(6)]],
                  device float *cw [[buffer(7)]],
                  uint3 tg [[threadgroup_position_in_grid]],
                  ushort lane [[thread_index_in_simdgroup]],
                  ushort sg [[simdgroup_index_in_threadgroup]])
{
  threadgroup float tsel[VSG * 32];
  threadgroup float rp[VSG];
  threadgroup float rmx[VSG];
  threadgroup float bm[VSG * 32];
  uint tid = uint(sg) * 32u + lane;
  uint hq = P.h / 4u;
  uint q0 = min(tid * 4u, hq - 4u);
  bool active = tid * 4u < hq;
  uint t = tg.x;
  float v[BL];
  float bmax = 0.0f;
  for(uint c = 0; c < 4; ++c)
  {
    float4 v4 = active ? x[t * hq + q0 + c] : float4(0.0f);
    v[4 * c] = v4.x;
    v[4 * c + 1] = v4.y;
    v[4 * c + 2] = v4.z;
    v[4 * c + 3] = v4.w;
    bmax = max(bmax, max(max(abs(v4.x), abs(v4.y)), max(abs(v4.z), abs(v4.w))));
  }
  bool expert = tid < P.ne;
  float logit = lg[t * P.ne + min(tid, P.ne - 1u)];
  float mine = expert ? sigmoidf(logit) + (P.has_bias != 0u ? bias[min(tid, P.ne - 1u)] : 0.0f) : -1e30f;
  tsel[tid] = mine;
  bm[tid] = bmax;
  float smax = simd_max(bmax);
  if(lane == 0) rmx[sg] = smax;
  BARRIER;
  uint rank = 0u;
  for(uint e = 0; e < P.ne; ++e)
  {
    float other = tsel[e];
    rank += (other > mine || (other == mine && e < tid)) ? 1u : 0u;
  }
  bool take = expert && rank < P.topk;
  float pw = sigmoidf(logit);
  float part = simd_sum(take ? pw : 0.0f);
  if(lane == 0) rp[sg] = part;
  BARRIER;
  if(take)
  {
    float den = 0.0f;
    for(uint i = 0; i < VSG; ++i) den += rp[i];
    chosen[t * P.topk + rank] = tid;
    cw[t * P.topk + rank] = pw * (P.route_scale / den);
  }
  float row_max = 0.0f;
  for(uint i = 0; i < VSG; ++i) row_max = max(row_max, rmx[i]);
  if(P.mode == 1u)
  {
    quantize_nvfp4_block(v, row_max);
    if(tid == 0u) xmax[t] = row_max;
  }
  else if(P.mode == 2u)
  {
    quantize_mxfp8_half(v, max(bm[tid], bm[tid ^ 1u]));
  }
  if(active)
  {
    for(uint c = 0; c < 4; ++c) xq[t * hq + q0 + c] = float4(v[4 * c], v[4 * c + 1], v[4 * c + 2], v[4 * c + 3]);
  }
}

// Experts, gate and up projections: rows 2 i (gate) and 2 i + 1 (up) of the
// route's expert, then the gated activation times the route's weight.

struct gu_params
{
  uint topk;
  uint rows;
  uint cols;
  uint quant;
  float gate_cap;
  float up_cap;
  float den;
};

kernel void gate_up_nvfp4(constant gu_params &P [[buffer(0)]],
                          device const uint *w [[buffer(1)]],
                          device const uchar *sc [[buffer(2)]],
                          device const float *wmax [[buffer(3)]],
                          device const float4 *xq [[buffer(4)]],
                          device const float *xmax [[buffer(5)]],
                          device const uint *chosen [[buffer(6)]],
                          device const float *cw [[buffer(7)]],
                          device const float *e4m3 [[buffer(8)]],
                          device float *act [[buffer(9)]],
                          uint3 tg [[threadgroup_position_in_grid]],
                          ushort lane [[thread_index_in_simdgroup]])
{
  // GU_ROWS rows a simdgroup (gate and up pairs). A row's sum is the same
  // whatever GU_ROWS is: more rows only put more loads in flight at once.
  uint route = tg.y;
  uint t = route / P.topk;
  uint e = chosen[route];
  uint row0 = tg.x * GU_ROWS;
  uint nb = P.cols / 16u;
  float acc[GU_ROWS];
  for(uint r = 0; r < GU_ROWS; ++r) acc[r] = 0.0f;
  for(uint b = lane; b < nb; b += 32u)
  {
    float4 xb[4];
    for(uint i = 0; i < 4; ++i) xb[i] = xq[t * (P.cols / 4u) + b * 4u + i];
    for(uint r = 0; r < GU_ROWS; ++r)
    {
      uint off = e * P.rows + row0 + r;
      uint2 q = ((device const uint2 *)w)[off * (P.cols / 16u) + b];
      float4 d = e2m1v(q.x) * xb[0] + e2m1v(q.x >> 16) * xb[1] + e2m1v(q.y) * xb[2] + e2m1v(q.y >> 16) * xb[3];
      acc[r] += hsum(d) * e4m3[sc[off * nb + b]];
    }
  }
  float a[GU_ROWS];
  for(uint r = 0; r < GU_ROWS; ++r) a[r] = simd_sum(acc[r]);
  if(lane == 0)
  {
    float outer = P.quant != 0u ? (xmax[t] * wmax[e]) / (P.den * 1536.0f) : wmax[e] / P.den;
    for(uint pr = 0; pr < GU_ROWS / 2u; ++pr)
    {
      float gate = rbf(a[2u * pr] * outer);
      float up = rbf(a[2u * pr + 1u] * outer);
      act[route * (P.rows / 2u) + tg.x * (GU_ROWS / 2u) + pr]
        = rbf(softcap(gate, P.gate_cap) * sigmoidf(gate) * softcap(up, P.up_cap) * cw[route]);
    }
  }
}

kernel void gate_up_mxfp8(constant gu_params &P [[buffer(0)]],
                          device const uchar4 *w [[buffer(1)]],
                          device const uchar *sc [[buffer(2)]],
                          device const float4 *xq [[buffer(4)]],
                          device const uint *chosen [[buffer(6)]],
                          device const float *cw [[buffer(7)]],
                          device float *act [[buffer(9)]],
                          uint3 tg [[threadgroup_position_in_grid]],
                          ushort lane [[thread_index_in_simdgroup]])
{
  uint route = tg.y;
  uint t = route / P.topk;
  uint e = chosen[route];
  uint row0 = tg.x * 4u;
  uint nb = P.cols / 32u;
  float acc[4] = { 0.0f, 0.0f, 0.0f, 0.0f };
  for(uint b = lane; b < nb; b += 32u)
  {
    float4 xb[8];
    for(uint i = 0; i < 8; ++i) xb[i] = xq[t * (P.cols / 4u) + b * 8u + i];
    for(uint r = 0; r < 4; ++r)
    {
      uint off = e * P.rows + row0 + r;
      float4 d = float4(0.0f);
      for(uint i = 0; i < 8; ++i) d += e4m3v(w[off * (P.cols / 4u) + b * 8u + i]) * xb[i];
      acc[r] += hsum(d) * exp2(float(sc[off * nb + b]) - 127.0f);
    }
  }
  float a[4];
  for(uint r = 0; r < 4; ++r) a[r] = simd_sum(acc[r]);
  if(lane == 0)
  {
    for(uint pr = 0; pr < 2; ++pr)
    {
      float gate = rbf(a[2u * pr]);
      float up = rbf(a[2u * pr + 1u]);
      act[route * (P.rows / 2u) + tg.x * 2u + pr]
        = rbf(softcap(gate, P.gate_cap) * sigmoidf(gate) * softcap(up, P.up_cap) * cw[route]);
    }
  }
}

// Quantizes each route's activations, in place: the down projection's input.

struct aq_params
{
  uint width;
  uint mode; // 1: NVFP4, 2: MXFP8
};

kernel void act_quant(constant aq_params &P [[buffer(0)]],
                      device float4 *act [[buffer(1)]],
                      device float *amax [[buffer(2)]],
                      uint3 tg [[threadgroup_position_in_grid]],
                      ushort lane [[thread_index_in_simdgroup]],
                      ushort sg [[simdgroup_index_in_threadgroup]])
{
  threadgroup float rmx[3];
  threadgroup float bm[96];
  uint tid = uint(sg) * 32u + lane;
  uint c0 = tid * BL;
  bool active = c0 < P.width;
  uint route = tg.x;
  uint wq = P.width / 4u;
  uint q0 = min(tid * 4u, wq - 4u);
  float v[BL];
  float bmax = 0.0f;
  for(uint c = 0; c < 4; ++c)
  {
    float4 v4 = active ? act[route * wq + q0 + c] : float4(0.0f);
    v[4 * c] = v4.x;
    v[4 * c + 1] = v4.y;
    v[4 * c + 2] = v4.z;
    v[4 * c + 3] = v4.w;
    bmax = max(bmax, max(max(abs(v4.x), abs(v4.y)), max(abs(v4.z), abs(v4.w))));
  }
  float smax = simd_max(bmax);
  if(lane == 0) rmx[sg] = smax;
  bm[tid] = bmax;
  BARRIER;
  float row_max = max(rmx[0], max(rmx[1], rmx[2]));
  if(P.mode == 1u)
  {
    quantize_nvfp4_block(v, row_max);
    if(tid == 0u) amax[route] = row_max;
  }
  else
  {
    quantize_mxfp8_half(v, max(bm[tid], bm[tid ^ 1u]));
  }
  if(active)
  {
    for(uint c = 0; c < 4; ++c) act[route * wq + q0 + c] = float4(v[4 * c], v[4 * c + 1], v[4 * c + 2], v[4 * c + 3]);
  }
}

// Experts, down projection: each route's row, rounded, summed over the
// token's routes.

struct dn_params
{
  uint topk;
  uint rows;
  uint cols;
  uint quant;
  float den;
};

kernel void down_nvfp4(constant dn_params &P [[buffer(0)]],
                       device const uint *w [[buffer(1)]],
                       device const uchar *sc [[buffer(2)]],
                       device const float *wmax [[buffer(3)]],
                       device const float4 *act [[buffer(4)]],
                       device const float *amax [[buffer(5)]],
                       device const uint *chosen [[buffer(6)]],
                       device const float *e4m3 [[buffer(8)]],
                       device float *ffn [[buffer(9)]],
                       uint3 tg [[threadgroup_position_in_grid]],
                       ushort lane [[thread_index_in_simdgroup]])
{
  // DN_ROWS rows a simdgroup; a row's sum is the same whatever DN_ROWS is.
  uint t = tg.y;
  uint row0 = tg.x * DN_ROWS;
  uint nb = P.cols / 16u;
  float total[DN_ROWS];
  for(uint r = 0; r < DN_ROWS; ++r) total[r] = 0.0f;
  for(uint j = 0; j < P.topk; ++j)
  {
    uint route = t * P.topk + j;
    uint e = chosen[route];
    float acc[DN_ROWS];
    for(uint r = 0; r < DN_ROWS; ++r) acc[r] = 0.0f;
    for(uint b = lane; b < nb; b += 32u)
    {
      float4 xb[4];
      for(uint i = 0; i < 4; ++i) xb[i] = act[route * (P.cols / 4u) + b * 4u + i];
      for(uint r = 0; r < DN_ROWS; ++r)
      {
        uint off = e * P.rows + row0 + r;
        uint2 q = ((device const uint2 *)w)[off * (P.cols / 16u) + b];
        float4 d = e2m1v(q.x) * xb[0] + e2m1v(q.x >> 16) * xb[1] + e2m1v(q.y) * xb[2] + e2m1v(q.y >> 16) * xb[3];
        acc[r] += hsum(d) * e4m3[sc[off * nb + b]];
      }
    }
    float outer = P.quant != 0u ? (amax[route] * wmax[e]) / (P.den * 1536.0f) : wmax[e] / P.den;
    for(uint r = 0; r < DN_ROWS; ++r) total[r] += rbf(simd_sum(acc[r]) * outer);
  }
  if(lane == 0)
  {
    for(uint r = 0; r < DN_ROWS; ++r) ffn[t * P.rows + row0 + r] = rbf(total[r]);
  }
}

kernel void down_mxfp8(constant dn_params &P [[buffer(0)]],
                       device const uchar4 *w [[buffer(1)]],
                       device const uchar *sc [[buffer(2)]],
                       device const float4 *act [[buffer(4)]],
                       device const uint *chosen [[buffer(6)]],
                       device float *ffn [[buffer(9)]],
                       uint3 tg [[threadgroup_position_in_grid]],
                       ushort lane [[thread_index_in_simdgroup]])
{
  uint t = tg.y;
  uint row0 = tg.x * 2u;
  uint nb = P.cols / 32u;
  float total[2] = { 0.0f, 0.0f };
  for(uint j = 0; j < P.topk; ++j)
  {
    uint route = t * P.topk + j;
    uint e = chosen[route];
    float acc[2] = { 0.0f, 0.0f };
    for(uint b = lane; b < nb; b += 32u)
    {
      float4 xb[8];
      for(uint i = 0; i < 8; ++i) xb[i] = act[route * (P.cols / 4u) + b * 8u + i];
      for(uint r = 0; r < 2; ++r)
      {
        uint off = e * P.rows + row0 + r;
        float4 d = float4(0.0f);
        for(uint i = 0; i < 8; ++i) d += e4m3v(w[off * (P.cols / 4u) + b * 8u + i]) * xb[i];
        acc[r] += hsum(d) * exp2(float(sc[off * nb + b]) - 127.0f);
      }
    }
    for(uint r = 0; r < 2; ++r) total[r] += rbf(simd_sum(acc[r]));
  }
  if(lane == 0)
  {
    for(uint r = 0; r < 2; ++r) ffn[t * P.rows + row0 + r] = rbf(total[r]);
  }
}

)MSL"

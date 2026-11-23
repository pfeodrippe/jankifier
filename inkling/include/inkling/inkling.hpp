// Inkling: an inference engine for Inkling 2 Mini (Thinking Machines'
// Inkling2LoopForConditionalGeneration), text only.
//
// The engine's data structures are public: a model's configuration, tensors,
// per-layer weights and execution plan, and a session's tokens, caches,
// logits and (with tracing on) the named intermediate values of its last
// evaluated token. jank includes this header and reads them directly.
//
// libinkling is built with jank's clang and libc++ (see the Makefile), so the
// standard library types here are the ones jank uses. Errors are thrown as
// std::runtime_error.
#pragma once

#include <array>
#include <cstdint>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <string_view>
#include <unordered_map>
#include <vector>

namespace inkling
{
  enum class dtype : int32_t
  {
    f32,
    bf16,
    u32,
    u8,
    i32,
    f16,
    i64
  };

  char const *dtype_name(dtype t);
  size_t dtype_size(dtype t);

  // A view of data: a tensor of the model file, or of a cache or trace.
  // Shapes are row-major.
  struct tensor
  {
    std::string name;
    dtype type{};
    std::vector<int64_t> shape;
    void const *data{};
    uint64_t nbytes{};

    int64_t numel() const;
    int64_t dim(int32_t i) const { return shape.at(static_cast<size_t>(i)); }
    // Element i (row-major) as a float; packed types give their raw integer.
    float get(int64_t i) const;
  };

  // The text model's configuration (config.json's text_config).
  struct config
  {
    int32_t layers{};
    int32_t hidden{};
    int32_t vocab{};
    int32_t unpadded_vocab{};
    int32_t context{};
    int32_t head_dim{};
    int32_t heads{};
    int32_t kv_heads{};
    int32_t local_head_dim{};
    int32_t local_heads{};
    int32_t local_kv_heads{};
    int32_t rel_dim{};
    int32_t rel_extent{};
    int32_t window{};
    int32_t conv_taps{};
    int32_t experts{};
    int32_t top_k{};
    int32_t expert_width{};
    int32_t residual_block{};
    bool loop{};
    int32_t loop_start{};
    int32_t loop_end{};
    int32_t loop_passes{};
    int32_t gate_rank{};
    float norm_eps{};
    float qk_clip{};
    float rel_clip{};
    float log_floor{};
    float log_alpha{};
    float route_scale{};
    float gate_cap{};
    float up_cap{};
    float logit_cap{};
    std::vector<int32_t> local_layers;
    int32_t eos_token{};
  };

  // One step of the decoder: a physical layer, which pass of the loop runs
  // it, and whether its attention is local (a sliding window).
  struct visit
  {
    int32_t layer{};
    int32_t pass{};
    bool local{};
  };

  // A short causal convolution over time. Fixed: `weight` [channels, 1, taps],
  // taps in chronological order. Projected: `static_w` [taps, channels] plus
  // per-token taps from `weight_proj` [heads * taps, hidden], indexed by lag.
  struct short_conv
  {
    tensor const *weight{};
    tensor const *static_w{};
    tensor const *weight_proj{};
    int32_t heads{};
    int32_t channels{};
  };

  struct attention_weights
  {
    tensor const *wq{};
    tensor const *wk{};
    tensor const *wv{};
    tensor const *wo{};
    tensor const *wr{};
    tensor const *gate{};
    tensor const *sink{};
    tensor const *rel_proj{};
    tensor const *q_scale{};
    tensor const *r_scale{};
    short_conv k_conv;
    short_conv v_conv;
    int32_t head_dim{};
    int32_t heads{};
    int32_t kv_heads{};
    int32_t window{};
    int32_t rel_extent{};
  };

  // A loop controller: mixes the previous pass's output into a layer input.
  struct message_gate
  {
    tensor const *down{};
    tensor const *gain{};
    tensor const *forget{};
  };

  // Routed experts' weights. NVFP4: packed E2M1 values ([experts, rows,
  // cols / 8] u32), an E4M3 scale per 16 columns ([experts, rows, cols / 16]
  // u8), and a per-expert scale amax / denominator. MXFP8 (the last layers):
  // E4M3 values ([experts, rows, cols / 4] u32) and a power-of-two (E8M0)
  // scale per 32 columns; no per-expert scale.
  struct expert_bank
  {
    bool nvfp4{};
    tensor const *weight{};
    tensor const *scales{};
    tensor const *amax{};
    tensor const *denominator{};
    int32_t rows{};
    int32_t cols{};
  };

  struct layer_weights
  {
    int32_t index{};
    bool local{};
    attention_weights attn;
    std::array<tensor const *, 3> attn_norm{};
    // Residual-mix query of the attention inputs: [hidden] or, for a global
    // layer, [3, hidden] (q, k, v). Absent for layer 0.
    tensor const *attn_query{};
    short_conv attn_conv;
    tensor const *router{};
    tensor const *router_bias{};
    expert_bank gate_up;
    expert_bank down;
    tensor const *mlp_norm{};
    tensor const *mlp_query{};
    short_conv mlp_conv;
    // Loop layers: controllers for q, k, v and feed-forward inputs, and the
    // queries [4, hidden] mixing the previous pass into their messages.
    std::vector<message_gate> messages;
    std::vector<float> message_queries;
  };

  struct tokenizer
  {
    std::vector<std::string> pieces;
    std::unordered_map<std::string, int32_t> ids;
    std::vector<bool> special;
    std::vector<std::pair<std::string, int32_t>> specials;
    // (left << 32 | right) -> (rank << 32 | merged id)
    std::unordered_map<uint64_t, uint64_t> merges;
    bool ignore_merges{};
  };

  struct pool;
  struct metal_backend;
  struct metal_session;

  // Parts of a visit that can be switched off (model::ablate).
  enum ablation : uint8_t
  {
    no_attention = 1, // attention adds nothing to the stream (keys and values are still cached)
    no_feed_forward = 2, // the experts add nothing
    no_messages = 4 // a later pass of the loop ignores the previous pass (no controllers)
  };

  struct model
  {
    std::string path;
    config cfg;
    std::vector<tensor> tensors;
    std::unordered_map<std::string, size_t> index;
    std::map<std::string, std::string_view> files;
    std::vector<visit> plan;
    std::vector<layer_weights> layers;
    tensor const *embed{};
    tensor const *embed_norm{};
    tensor const *unembed{};
    tensor const *out_norm{};
    tensor const *out_query{};
    inkling::tokenizer tok;
    int32_t threads{};
    // Quantize the experts' inputs as the checkpoint's reference does (NVFP4
    // with 4-over-6 block scales, or MXFP8). Off: FP32 inputs.
    bool quantize_expert_inputs{ true };
    // One token over a context of 2,048 tokens or more on the GPU: the global
    // layers' attention split across the keys and merged (att_split, att_merge)
    // rather than a threadgroup a head. The same arithmetic in another order.
    bool split_attention{ true };
    // Experiments. ablate has a set of `ablation` bits per visit of the plan,
    // and banned_experts, per layer, experts the router may not choose.
    // While any is set, evals run on the CPU path, which implements them.
    std::vector<uint8_t> ablate;
    std::vector<std::vector<int32_t>> banned_experts;
    bool ablated() const;
    // The Metal backend, when the machine and the model's sizes allow it
    // (null otherwise). use_gpu chooses it for evals; sessions made while a
    // model has a backend can run on either.
    metal_backend *gpu{};
    bool use_gpu{ true };

    void const *map{};
    size_t map_size{};
    std::unique_ptr<inkling::pool> workers;
    // One forward pass at a time on a model: evals of its sessions from
    // different threads wait for each other (the workers, and the weight
    // copies made on first use, are the model's).
    std::mutex running;

    model();
    ~model();
    model(model const &) = delete;
    model &operator=(model const &) = delete;

    tensor const *find(std::string_view name) const;
    tensor const &at(std::string_view name) const;
    // A tensor's values as F32 (converted once and kept).
    float const *f32(tensor const *t) const;
    mutable std::unordered_map<tensor const *, std::vector<float>> f32_copies;
  };

  // Opens a model file written by convert.
  model *open(std::string const &path);
  void close(model *m);
  void set_threads(model &m, int32_t n);

  // Converts a checkpoint into a model file. `source` is a directory of
  // safetensors files with config.json and the tokenizer files, or a
  // manifest listing tensor blobs (Ollama's `manifests/.../<tag>`; the blobs
  // are read from the `blobs` directory beside `manifests`).
  void convert(std::string const &source, std::string const &out_path);

  std::vector<int32_t> tokenize(model const &m, std::string_view text, bool special);
  std::string detokenize(model const &m, int32_t const *ids, size_t n);
  std::string detokenize(model const &m, std::vector<int32_t> const &ids);
  int32_t token_id(model const &m, std::string_view piece);

  // A named value recorded while tracing, for the last token of an eval.
  struct trace_entry
  {
    std::string name;
    std::vector<int64_t> shape;
    std::vector<float> values;
  };

  // The caches of one visit. Keys and values are [slots, kv_heads, head_dim]
  // IEEE halves: the reference's BF16-rounded value, held in a half so that
  // the GPU can load blocks of them directly (a value below 2^-17 in
  // magnitude loses its last bits). Their buffers have rows up to a
  // multiple of 32 slots. A local visit keeps a ring of window + chunk positions (slot =
  // pos % slots). conv: the last taps - 1 inputs of the key, value,
  // attention-output and feed-forward-output convolutions, F32 [taps - 1,
  // conv_width].
  //
  // The memory is shared by the CPU and the GPU (Metal buffers), or mapped
  // lazily when there's no GPU backend.
  struct visit_cache
  {
    int32_t slots{};
    int32_t kv_heads{};
    int32_t head_dim{};
    uint16_t *k{};
    uint16_t *v{};
    std::array<float *, 4> conv{};
    std::array<int32_t, 4> conv_width{};

    // Elements of k (and of v), with the padding rows.
    size_t kv_elements() const { return static_cast<size_t>((slots + 31) / 32 * 32) * kv_heads * head_dim; }
    // Slot of a position.
    int32_t slot(int32_t pos) const { return pos % slots; }
  };

  // The values of one visit for every token of a chunk, at the points where
  // the CPU and GPU paths are compared (check.cpp). Row-major; the first
  // dimension is the token.
  struct visit_capture
  {
    // The controllers of a visit with messages (q, k, v, feed-forward): the
    // normalized pair of input and message [T, 2 hidden], and its low-rank
    // projection [T, gate_rank].
    std::array<std::vector<float>, 4> pairs, compressed;
    // The normalized attention inputs of q, k and v: [T, hidden].
    std::array<std::vector<float>, 3> inputs;
    // Projections as they come out (rounded), before the clip or the
    // convolution: queries, relative features, keys, values, the projected
    // convolution taps of a global visit [T, kv_heads * taps], and attention's
    // output [T, hidden]; and the keys and values after their convolution.
    std::vector<float> q_proj, r_proj, k_proj, v_proj, k_taps, v_taps, k_conv, v_conv, attn_proj;
    // Queries and relative features after the clip, [T, heads * head_dim] and
    // [T, heads * rel_dim]; sink logits [T, heads]; the output gate's
    // projection [T, heads * head_dim].
    std::vector<float> q, r, sink, gate;
    // The keys and values written to the cache: halves [T, kv_heads * head_dim].
    std::vector<uint16_t> k, v;
    // The convolution histories after the visit (as in visit_cache).
    std::array<std::vector<float>, 4> conv;
    // Attention's gated output before its projection: [T, heads * head_dim].
    std::vector<float> attended;
    // The stream's partial sum after attention, and after the visit: [T, hidden].
    std::vector<float> after_attention, partial;
    // The normalized feed-forward input: [T, hidden].
    std::vector<float> ffn_input;
    // Router logits [T, experts]; the chosen experts by decreasing score and
    // their weights: [T, top_k].
    std::vector<float> router;
    std::vector<int32_t> experts;
    std::vector<float> expert_weights;
    // The experts' input as they read it (quantized: inner values and each
    // token's maximum): [T, hidden], [T].
    std::vector<float> expert_input, expert_input_max;
    // The gated activations, [T, top_k, expert_width]: as computed, and as
    // the down projection reads them (quantized), with each route's maximum
    // [T, top_k].
    std::vector<float> activations_raw, activations, activation_max;
    // The experts' output before its convolution: [T, hidden]. ffn_routes
    // (CPU only) has each route's part of it, [T, top_k, hidden]: each is
    // rounded before they are summed.
    std::vector<float> ffn, ffn_routes;
  };

  // A forward pass's values: see session::capturing.
  struct capture
  {
    int32_t tokens{};
    int32_t pos{};
    std::vector<float> embed;
    std::vector<visit_capture> visits;
    std::vector<float> hidden;
    std::vector<float> logits;
  };

  // A step of the Metal forward's residual stream bookkeeping (metal.mm): the
  // stream's blocks and partial sum live in numbered slots of one buffer.
  // visit is -1 for the embeddings and the plan's size for the output.
  struct stream_event
  {
    enum class kind : int32_t
    {
      take, // a free slot becomes the partial sum
      push, // the partial sum's slot becomes a block
      restart, // a loop pass starts again from the prelude's slot
      release, // a slot returns to the free list
      read, // a kernel of this visit reads the slot
      write // a kernel of this visit writes the slot
    };

    kind k{};
    int32_t visit{};
    int32_t slot{};
  };

  struct scratch;

  // The state of one sequence. Several sessions can share a model.
  struct session
  {
    inkling::model *model{};
    int32_t context{};
    int32_t pos{};
    std::vector<int32_t> tokens;
    std::vector<visit_cache> caches;
    std::vector<float> logits;
    // Tracing: evals run on the CPU and record the named values of their
    // last token.
    bool trace{};
    std::vector<trace_entry> traces;
    std::unique_ptr<inkling::scratch> work;
    // Capturing: each forward (CPU or GPU) fills `captured` with the values
    // of its chunk. On the GPU this runs every stage in its own command
    // buffer, so it is slow.
    bool capturing{};
    inkling::capture captured;
    // Recording: the Metal forward lists its stream bookkeeping in `events`.
    bool record{};
    std::vector<stream_event> events;
    metal_session *gpu{};
    std::vector<std::pair<void *, size_t>> maps;

    session();
    ~session();
    session(session const &) = delete;
    session &operator=(session const &) = delete;

    trace_entry const *find_trace(std::string_view name) const;
  };

  // Tokens evaluated per forward (longer inputs are split into chunks).
  inline constexpr int32_t max_chunk{ 64 };

  session *new_session(model &m, int32_t context);
  void free_session(session *s);
  void reset(session &s);
  void copy(session &dst, session const &src);
  // Evaluates tokens at the end of the sequence; the logits of the last one
  // are then in s.logits.
  void eval(session &s, int32_t const *ids, size_t n);
  void eval(session &s, std::vector<int32_t> const &ids);

  // A comparison of two captures, field by field (GPU against CPU).
  struct check_row
  {
    int32_t visit{}; // -1: embeddings; the plan's size: the output
    std::string field;
    int64_t count{}; // values compared
    int64_t different{}; // values that aren't bitwise equal
    int64_t beyond{}; // values further apart than the field's tolerance
    double worst{}; // the largest difference, in the field's unit (see check.cpp)
  };

  struct check_report
  {
    std::vector<check_row> rows;
    int64_t compared{};
    int64_t beyond{};
    bool ok() const { return beyond == 0; }
  };

  // Evaluates ids at the end of the session on the CPU, then again on the
  // GPU from the same state, forcing the CPU's values in after every stage of
  // every visit, so each GPU stage is compared on identical inputs. The
  // session ends as after eval on the CPU.
  check_report check_gpu(session &s, std::vector<int32_t> const &ids);

  // Samples from logits. temperature <= 0 is greedy (argmax).
  int32_t sample(float const *logits, int32_t n, float temperature, float top_p, int32_t top_k, uint64_t &rng);
}

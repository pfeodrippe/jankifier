// The model file: conversion from a checkpoint, loading (mmap), the
// configuration, the execution plan and the per-layer weights.
//
// Model file layout: "INKLING1", a u64 header length, a JSON header, then the
// data from the next multiple of 16 KiB. The header lists tensors (name,
// dtype, shape, offset, size) and embedded files (config.json, tokenizer
// files); offsets are relative to the data start and multiples of 16 KiB, so
// each tensor can back a Metal buffer without copying.
#include "internal.hpp"
#include "json.hpp"

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <filesystem>
#include <fstream>

#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <unistd.h>

namespace fs = std::filesystem;

namespace inkling
{
  namespace
  {
    constexpr char magic[8]{ 'I', 'N', 'K', 'L', 'I', 'N', 'G', '1' };
    constexpr uint64_t alignment{ 16384 };

    uint64_t align_up(uint64_t const x)
    {
      return (x + alignment - 1) / alignment * alignment;
    }

    dtype parse_dtype(std::string const &s)
    {
      if(s == "F32")
      {
        return dtype::f32;
      }
      if(s == "BF16")
      {
        return dtype::bf16;
      }
      if(s == "U32")
      {
        return dtype::u32;
      }
      if(s == "U8")
      {
        return dtype::u8;
      }
      if(s == "I32")
      {
        return dtype::i32;
      }
      if(s == "F16")
      {
        return dtype::f16;
      }
      if(s == "I64")
      {
        return dtype::i64;
      }
      fail("unsupported dtype " + s);
    }

    std::string read_file(fs::path const &p)
    {
      std::ifstream in{ p, std::ios::binary };
      if(!in)
      {
        fail("can't read " + p.string());
      }
      return { std::istreambuf_iterator<char>{ in }, std::istreambuf_iterator<char>{} };
    }

    // A tensor to copy from a safetensors file into the model file.
    struct source_tensor
    {
      std::string name;
      std::string dtype;
      std::vector<int64_t> shape;
      std::string file;
      uint64_t offset{};
      uint64_t size{};
    };

    struct source_file
    {
      std::string name;
      std::string file;
    };

    void read_safetensors(std::string const &path, std::vector<source_tensor> &out)
    {
      std::ifstream in{ path, std::ios::binary };
      if(!in)
      {
        fail("can't read " + path);
      }
      uint64_t n{};
      in.read(reinterpret_cast<char *>(&n), 8);
      if(!in || n > (1ull << 30))
      {
        fail("bad safetensors header in " + path);
      }
      std::string header(n, '\0');
      in.read(header.data(), static_cast<std::streamsize>(n));
      auto const h{ json::parse(header) };
      for(auto const &[name, v] : h.fields())
      {
        if(name == "__metadata__")
        {
          continue;
        }
        source_tensor t;
        t.name = name;
        t.dtype = v.at("dtype").str();
        for(auto const &d : v.at("shape").items())
        {
          t.shape.push_back(d.integer());
        }
        auto const &offsets{ v.at("data_offsets").items() };
        t.file = path;
        t.offset = 8 + n + static_cast<uint64_t>(offsets.at(0).integer());
        t.size = static_cast<uint64_t>(offsets.at(1).integer() - offsets.at(0).integer());
        out.push_back(std::move(t));
      }
    }
  }

  char const *dtype_name(dtype const t)
  {
    switch(t)
    {
      case dtype::f32:
        return "f32";
      case dtype::bf16:
        return "bf16";
      case dtype::u32:
        return "u32";
      case dtype::u8:
        return "u8";
      case dtype::i32:
        return "i32";
      case dtype::f16:
        return "f16";
      case dtype::i64:
        return "i64";
    }
    return "?";
  }

  size_t dtype_size(dtype const t)
  {
    switch(t)
    {
      case dtype::f32:
      case dtype::u32:
      case dtype::i32:
        return 4;
      case dtype::bf16:
      case dtype::f16:
        return 2;
      case dtype::u8:
        return 1;
      case dtype::i64:
        return 8;
    }
    return 0;
  }

  int64_t tensor::numel() const
  {
    int64_t n{ 1 };
    for(auto const d : shape)
    {
      n *= d;
    }
    return n;
  }

  float tensor::get(int64_t const i) const
  {
    if(i < 0 || i >= numel())
    {
      fail("index " + std::to_string(i) + " out of range for " + name);
    }
    switch(type)
    {
      case dtype::f32:
        return static_cast<float const *>(data)[i];
      case dtype::bf16:
        return bf16_to_f32(static_cast<uint16_t const *>(data)[i]);
      case dtype::u32:
        return static_cast<float>(static_cast<uint32_t const *>(data)[i]);
      case dtype::u8:
        return static_cast<float>(static_cast<uint8_t const *>(data)[i]);
      case dtype::i32:
        return static_cast<float>(static_cast<int32_t const *>(data)[i]);
      case dtype::f16:
        return static_cast<float>(static_cast<_Float16 const *>(data)[i]);
      case dtype::i64:
        return static_cast<float>(static_cast<int64_t const *>(data)[i]);
    }
    return 0;
  }

  void convert(std::string const &source, std::string const &out_path)
  {
    std::vector<source_tensor> tensors;
    std::vector<source_file> files;
    fs::path const src{ source };
    if(fs::is_directory(src))
    {
      std::vector<fs::path> shards;
      for(auto const &e : fs::directory_iterator{ src })
      {
        if(e.path().extension() == ".safetensors")
        {
          shards.push_back(e.path());
        }
      }
      std::sort(shards.begin(), shards.end());
      for(auto const &p : shards)
      {
        read_safetensors(p.string(), tensors);
      }
      for(char const *name : { "config.json",
                               "generation_config.json",
                               "tokenizer.json",
                               "tokenizer_config.json",
                               "special_tokens_map.json",
                               "processor_config.json",
                               "hf_quant_config.json",
                               "draft/config.json" })
      {
        if(fs::exists(src / name))
        {
          files.push_back({ name, (src / name).string() });
        }
      }
    }
    else
    {
      // A manifest: its blobs are in <root>/blobs, beside <root>/manifests.
      auto const manifest{ json::parse(read_file(src)) };
      fs::path root{ src };
      while(!root.empty() && root.filename() != "manifests")
      {
        root = root.parent_path();
      }
      if(root.empty())
      {
        fail("the manifest " + source + " isn't under a manifests directory");
      }
      auto const blobs{ root.parent_path() / "blobs" };
      for(auto const &layer : manifest.at("layers").items())
      {
        auto const &media{ layer.at("mediaType").str() };
        auto digest{ layer.at("digest").str() };
        std::replace(digest.begin(), digest.end(), ':', '-');
        auto const path{ (blobs / digest).string() };
        auto const name{ layer.get("name") };
        if(media == "application/vnd.ollama.image.tensor")
        {
          read_safetensors(path, tensors);
        }
        else if(media == "application/vnd.ollama.image.json" && name)
        {
          files.push_back({ name->str(), path });
        }
      }
    }
    if(tensors.empty())
    {
      fail("no tensors in " + source);
    }
    std::sort(tensors.begin(), tensors.end(), [](auto const &a, auto const &b) { return a.name < b.name; });

    // Layout and header.
    uint64_t offset{};
    std::string header{ "{\"format\":1,\"tensors\":[" };
    for(size_t i{}; i < tensors.size(); ++i)
    {
      auto const &t{ tensors[i] };
      if(i)
      {
        header += ',';
      }
      header += "{\"name\":";
      json::escape_to(header, t.name);
      header += ",\"dtype\":\"" + t.dtype + "\",\"shape\":[";
      for(size_t d{}; d < t.shape.size(); ++d)
      {
        header += (d ? "," : "") + std::to_string(t.shape[d]);
      }
      header += "],\"offset\":" + std::to_string(offset) + ",\"size\":" + std::to_string(t.size) + "}";
      offset = align_up(offset + t.size);
    }
    header += "],\"files\":[";
    std::vector<std::string> contents;
    for(size_t i{}; i < files.size(); ++i)
    {
      contents.push_back(read_file(files[i].file));
      if(i)
      {
        header += ',';
      }
      header += "{\"name\":";
      json::escape_to(header, files[i].name);
      header += ",\"offset\":" + std::to_string(offset) + ",\"size\":" + std::to_string(contents.back().size()) + "}";
      offset = align_up(offset + contents.back().size());
    }
    header += "]}";
    uint64_t const data_start{ align_up(16 + header.size()) };
    uint64_t const total{ data_start + offset };

    auto const tmp{ out_path + ".partial" };
    int const fd{ ::open(tmp.c_str(), O_WRONLY | O_CREAT | O_TRUNC, 0644) };
    if(fd < 0)
    {
      fail("can't create " + tmp);
    }
    auto const put{ [&](void const *p, size_t n, uint64_t at) {
      auto const *c{ static_cast<char const *>(p) };
      while(n)
      {
        auto const w{ ::pwrite(fd, c, n, static_cast<off_t>(at)) };
        if(w <= 0)
        {
          ::close(fd);
          fail("write failed on " + tmp);
        }
        c += w;
        n -= static_cast<size_t>(w);
        at += static_cast<uint64_t>(w);
      }
    } };
    uint64_t const header_len{ header.size() };
    put(magic, 8, 0);
    put(&header_len, 8, 8);
    put(header.data(), header.size(), 16);

    std::vector<char> buf(64u << 20);
    uint64_t copied{};
    auto const started{ std::chrono::steady_clock::now() };
    offset = 0;
    for(auto const &t : tensors)
    {
      int const in{ ::open(t.file.c_str(), O_RDONLY) };
      if(in < 0)
      {
        ::close(fd);
        fail("can't read " + t.file);
      }
      uint64_t done{};
      while(done < t.size)
      {
        auto const n{ std::min<uint64_t>(buf.size(), t.size - done) };
        auto const r{ ::pread(in, buf.data(), n, static_cast<off_t>(t.offset + done)) };
        if(r <= 0)
        {
          ::close(in);
          ::close(fd);
          fail("short read of " + t.name);
        }
        put(buf.data(), static_cast<size_t>(r), data_start + offset + done);
        done += static_cast<uint64_t>(r);
      }
      ::close(in);
      offset = align_up(offset + t.size);
      copied += t.size;
      auto const secs{ std::chrono::duration<double>(std::chrono::steady_clock::now() - started).count() };
      std::fprintf(stderr, "\rinkling: converted %.1f / %.1f GB (%.0f s)", copied / 1e9, total / 1e9, secs);
    }
    for(auto const &c : contents)
    {
      put(c.data(), c.size(), data_start + offset);
      offset = align_up(offset + c.size());
    }
    if(::ftruncate(fd, static_cast<off_t>(total)) != 0)
    {
      ::close(fd);
      fail("can't size " + tmp);
    }
    ::close(fd);
    fs::rename(tmp, out_path);
    std::fprintf(stderr, "\ninkling: wrote %s (%zu tensors, %zu files)\n", out_path.c_str(), tensors.size(), files.size());
  }

  model::model() = default;

  model::~model()
  {
    metal_close(gpu);
    workers.reset();
    if(map)
    {
      ::munmap(const_cast<void *>(map), map_size);
    }
  }

  bool model::ablated() const
  {
    for(auto const bits : ablate)
    {
      if(bits)
      {
        return true;
      }
    }
    for(auto const &banned : banned_experts)
    {
      if(!banned.empty())
      {
        return true;
      }
    }
    return false;
  }

  tensor const *model::find(std::string_view const name) const
  {
    auto const it{ index.find(std::string{ name }) };
    return it == index.end() ? nullptr : &tensors[it->second];
  }

  tensor const &model::at(std::string_view const name) const
  {
    auto const t{ find(name) };
    if(!t)
    {
      fail("missing tensor " + std::string{ name });
    }
    return *t;
  }

  float const *model::f32(tensor const *t) const
  {
    if(!t)
    {
      return nullptr;
    }
    if(t->type == dtype::f32)
    {
      return static_cast<float const *>(t->data);
    }
    auto const it{ f32_copies.find(t) };
    if(it != f32_copies.end())
    {
      return it->second.data();
    }
    std::vector<float> v(static_cast<size_t>(t->numel()));
    for(int64_t i{}; i < t->numel(); ++i)
    {
      v[static_cast<size_t>(i)] = t->get(i);
    }
    return f32_copies.emplace(t, std::move(v)).first->second.data();
  }

  int32_t default_threads()
  {
    int32_t n{};
    size_t len{ sizeof(n) };
    if(::sysctlbyname("hw.perflevel0.physicalcpu", &n, &len, nullptr, 0) != 0 || n <= 0)
    {
      n = static_cast<int32_t>(std::max(1u, std::thread::hardware_concurrency()));
    }
    return n;
  }

  void set_threads(model &m, int32_t const n)
  {
    m.workers.reset();
    m.threads = std::max(1, n);
    m.workers = std::make_unique<pool>(m.threads - 1);
  }

  void load_tokenizer(model &m);

  namespace
  {
    config parse_config(std::string_view text)
    {
      auto const root{ json::parse(text) };
      auto const &t{ root.at("text_config") };
      auto const i32{ [&](char const *k) { return static_cast<int32_t>(t.at(k).integer()); } };
      auto const f32{ [&](char const *k) { return static_cast<float>(t.at(k).num()); } };
      config c;
      c.layers = i32("num_hidden_layers");
      c.hidden = i32("hidden_size");
      c.vocab = i32("vocab_size");
      c.unpadded_vocab = i32("unpadded_vocab_size");
      c.context = i32("model_max_length");
      c.head_dim = i32("head_dim");
      c.heads = i32("num_attention_heads");
      c.kv_heads = i32("num_key_value_heads");
      c.local_head_dim = i32("swa_head_dim");
      c.local_heads = i32("swa_num_attention_heads");
      c.local_kv_heads = i32("swa_num_key_value_heads");
      c.rel_dim = i32("d_rel");
      c.rel_extent = i32("rel_extent");
      c.window = i32("sliding_window_size");
      c.conv_taps = i32("sconv_kernel_size");
      c.experts = i32("n_routed_experts");
      c.top_k = i32("num_experts_per_tok");
      c.expert_width = i32("intermediate_size");
      c.residual_block = i32("n_layers_per_attn_res_block");
      c.norm_eps = f32("rms_norm_eps");
      c.qk_clip = f32("qk_l2_clip_threshold");
      c.rel_clip = f32("rel_l2_clip_threshold");
      c.log_floor = f32("log_scaling_n_floor");
      c.log_alpha = f32("log_scaling_alpha");
      c.route_scale = f32("route_scale");
      c.gate_cap = f32("mlp_gate_softcap");
      c.up_cap = f32("mlp_up_softcap");
      c.logit_cap = f32("final_logit_softcapping");
      for(auto const &l : t.at("local_layer_ids").items())
      {
        c.local_layers.push_back(static_cast<int32_t>(l.integer()));
      }
      if(auto const loop{ t.get("loop_config") }; loop && loop->is_object())
      {
        if(loop->at("is_varloop").boolean_or(false))
        {
          fail("variable loops are unsupported");
        }
        c.loop = true;
        c.loop_start = static_cast<int32_t>(loop->at("core_start").integer());
        c.loop_end = static_cast<int32_t>(loop->at("core_end").integer());
        c.loop_passes = static_cast<int32_t>(loop->at("num_passes").integer());
        c.gate_rank = static_cast<int32_t>(loop->at("gate_rank").integer());
      }
      if(auto const eos{ root.get("eos_token_id") }; eos && eos->is_number())
      {
        c.eos_token = static_cast<int32_t>(eos->integer());
      }
      if(c.loop && (c.loop_start % c.residual_block != 0 || c.loop_end % c.residual_block != 0 || c.loop_start < 0
                    || c.loop_end > c.layers || c.loop_start >= c.loop_end || c.loop_passes < 2))
      {
        fail("unsupported loop: it must cover whole residual blocks, at least twice");
      }
      if(t.at("n_shared_experts").integer() != 0 || t.at("q_bias").boolean_or(false) || t.at("o_bias").boolean_or(false)
         || !t.at("use_value_norm_no_gamma").boolean_or(false) || !t.at("attn_res_normalize_values").boolean_or(false))
      {
        fail("unsupported configuration (shared experts, attention biases or unnormalized values)");
      }
      return c;
    }

    // Layers [0, loop_end), then passes 1.. of the loop's layers, then the
    // rest: the order the decoder runs them in.
    std::vector<visit> execution_plan(config const &c)
    {
      std::vector<bool> local(static_cast<size_t>(c.layers));
      for(auto const l : c.local_layers)
      {
        local.at(static_cast<size_t>(l)) = true;
      }
      std::vector<visit> plan;
      int32_t const end{ c.loop ? c.loop_end : c.layers };
      for(int32_t l{}; l < end; ++l)
      {
        plan.push_back({ l, 0, local[static_cast<size_t>(l)] });
      }
      if(c.loop)
      {
        for(int32_t p{ 1 }; p < c.loop_passes; ++p)
        {
          for(int32_t l{ c.loop_start }; l < c.loop_end; ++l)
          {
            plan.push_back({ l, p, local[static_cast<size_t>(l)] });
          }
        }
      }
      for(int32_t l{ end }; l < c.layers; ++l)
      {
        plan.push_back({ l, 0, local[static_cast<size_t>(l)] });
      }
      return plan;
    }

    std::string layer_name(int32_t const l, std::string_view rest)
    {
      return "model.llm.layers." + std::to_string(l) + "." + std::string{ rest };
    }

    short_conv conv_weights(model const &m, std::string const &prefix, int32_t channels, bool projected)
    {
      short_conv c;
      c.channels = channels;
      if(projected)
      {
        c.static_w = &m.at(prefix + ".static_w");
        c.weight_proj = &m.at(prefix + ".weight_proj");
        c.heads = static_cast<int32_t>(c.weight_proj->dim(0) / m.cfg.conv_taps);
      }
      else
      {
        c.weight = &m.at(prefix + ".weight");
      }
      return c;
    }

    expert_bank bank(model const &m, std::string const &name)
    {
      expert_bank b;
      b.weight = &m.at(name);
      b.scales = &m.at(name + "_scale");
      b.amax = m.find(name + "_amax");
      b.nvfp4 = b.amax != nullptr;
      if(b.nvfp4)
      {
        b.denominator = &m.at(name + "_outer_scale_denominator");
      }
      b.rows = static_cast<int32_t>(b.weight->dim(1));
      b.cols = static_cast<int32_t>(b.weight->dim(2) * (b.nvfp4 ? 8 : 4));
      return b;
    }

    void load_layers(model &m)
    {
      auto const &c{ m.cfg };
      m.layers.resize(static_cast<size_t>(c.layers));
      tensor const *cross_q{};
      tensor const *cross_kv{};
      if(c.loop)
      {
        cross_q = &m.at("model.llm.middle_cycle_cross_pass_queries");
        cross_kv = &m.at("model.llm.middle_cycle_cross_pass_kv_queries");
      }
      for(int32_t l{}; l < c.layers; ++l)
      {
        auto &w{ m.layers[static_cast<size_t>(l)] };
        w.index = l;
        w.local = std::find(c.local_layers.begin(), c.local_layers.end(), l) != c.local_layers.end();
        auto &a{ w.attn };
        auto const ap{ layer_name(l, "attn.") };
        a.wq = &m.at(ap + "wq_du.weight");
        a.wk = &m.at(ap + "wk_dv.weight");
        a.wv = &m.at(ap + "wv_dv.weight");
        a.wo = &m.at(ap + "wo_ud.weight");
        a.wr = &m.at(ap + "wr_du.weight");
        a.gate = &m.at(ap + "gate_attn.weight");
        a.sink = &m.at(ap + "attn_sink_proj.weight");
        a.rel_proj = &m.at(ap + "rel_logits_proj.proj");
        a.q_scale = &m.at(ap + "q_l2_clip.scale");
        a.r_scale = &m.at(ap + "rel_l2_clip.scale");
        a.head_dim = w.local ? c.local_head_dim : c.head_dim;
        a.heads = w.local ? c.local_heads : c.heads;
        a.kv_heads = w.local ? c.local_kv_heads : c.kv_heads;
        a.window = w.local ? c.window : 0;
        a.rel_extent = static_cast<int32_t>(a.rel_proj->dim(1));
        a.k_conv = conv_weights(m, ap + "k_sconv", a.kv_heads * a.head_dim, !w.local);
        a.v_conv = conv_weights(m, ap + "v_sconv", a.kv_heads * a.head_dim, !w.local);
        if(w.local)
        {
          auto const norm{ &m.at(layer_name(l, "attn_norm.weight")) };
          w.attn_norm = { norm, norm, norm };
        }
        else
        {
          w.attn_norm = { &m.at(layer_name(l, "q_input_norm.weight")),
                          &m.at(layer_name(l, "k_input_norm.weight")),
                          &m.at(layer_name(l, "v_input_norm.weight")) };
        }
        if(l > 0)
        {
          w.attn_query = &m.at("model.llm.attn_res.attn_queries." + std::to_string(l - 1));
        }
        w.attn_conv = conv_weights(m, layer_name(l, "attn_sconv"), c.hidden, false);
        w.mlp_conv = conv_weights(m, layer_name(l, "mlp_sconv"), c.hidden, false);
        w.router = &m.at(layer_name(l, "mlp.gate.weight"));
        w.router_bias = m.find(layer_name(l, "mlp.gate.bias"));
        w.gate_up = bank(m, layer_name(l, "mlp.experts.w13_weight"));
        w.down = bank(m, layer_name(l, "mlp.experts.w2_weight"));
        w.mlp_norm = &m.at(layer_name(l, "mlp_norm.weight"));
        w.mlp_query = &m.at("model.llm.attn_res.mlp_queries." + std::to_string(l));
        if(c.loop && l >= c.loop_start && l < c.loop_end)
        {
          for(char const *name : { "attn", "k", "v", "mlp" })
          {
            auto const stem{ layer_name(l, std::string{ "controllers." } + name + ".") };
            w.messages.push_back(
              { &m.at(stem + "down_weight"), &m.at(stem + "gain_weight"), &m.at(stem + "forget_weight") });
          }
          // Queries for the q, k, v and feed-forward messages.
          int32_t const row{ 2 * (l - c.loop_start) };
          auto const h{ static_cast<int64_t>(c.hidden) };
          auto const put{ [&](tensor const *t, int64_t r) {
            for(int64_t i{}; i < h; ++i)
            {
              w.message_queries.push_back(t->get(r * h + i));
            }
          } };
          put(cross_q, row);
          put(cross_kv, row);
          put(cross_kv, row + 1);
          put(cross_q, row + 1);
        }
      }
      m.embed = &m.at("model.llm.embed.weight");
      m.unembed = &m.at("model.llm.unembed.weight");
      m.embed_norm = &m.at("model.llm.embed_norm.weight");
      m.out_norm = &m.at("model.llm.norm.weight");
      m.out_query = &m.at("model.llm.attn_res.output_query");
    }

    // F32 copies of the small tensors the forward reads, made before any
    // thread reads them.
    void prepare(model &m)
    {
      for(auto const &t : m.tensors)
      {
        bool const big{ t.nbytes > (8u << 20) };
        bool const packed{ t.type == dtype::u32 || t.type == dtype::u8 };
        bool const projection{ t.name.find("_proj.weight") != std::string::npos || t.name.find("wq_du") != std::string::npos
                               || t.name.find("wk_dv") != std::string::npos || t.name.find("wv_dv") != std::string::npos
                               || t.name.find("wo_ud") != std::string::npos || t.name.find("wr_du") != std::string::npos
                               || t.name.find("gate_attn") != std::string::npos || t.name.find("down_weight") != std::string::npos };
        if(!big && !packed && !projection && t.name.rfind("model.llm.", 0) == 0)
        {
          m.f32(&t);
        }
      }
      for(auto const &w : m.layers)
      {
        m.f32(w.router);
        for(auto const &g : w.messages)
        {
          m.f32(g.gain);
          m.f32(g.forget);
        }
      }
    }
  }

  model *open(std::string const &path)
  {
    int const fd{ ::open(path.c_str(), O_RDONLY) };
    if(fd < 0)
    {
      fail("can't open " + path);
    }
    struct stat st{};
    ::fstat(fd, &st);
    auto const size{ static_cast<size_t>(st.st_size) };
    void *const p{ ::mmap(nullptr, size, PROT_READ, MAP_SHARED, fd, 0) };
    ::close(fd);
    if(p == MAP_FAILED)
    {
      fail("can't map " + path);
    }
    auto m{ std::make_unique<model>() };
    m->path = path;
    m->map = p;
    m->map_size = size;
    auto const *bytes{ static_cast<char const *>(p) };
    if(size < 16 || std::memcmp(bytes, magic, 8) != 0)
    {
      fail(path + " isn't an inkling model file");
    }
    uint64_t header_len{};
    std::memcpy(&header_len, bytes + 8, 8);
    auto const header{ json::parse(std::string_view{ bytes + 16, header_len }) };
    auto const data{ bytes + align_up(16 + header_len) };
    for(auto const &t : header.at("tensors").items())
    {
      tensor x;
      x.name = t.at("name").str();
      x.type = parse_dtype(t.at("dtype").str());
      for(auto const &d : t.at("shape").items())
      {
        x.shape.push_back(d.integer());
      }
      x.data = data + t.at("offset").integer();
      x.nbytes = static_cast<uint64_t>(t.at("size").integer());
      m->index.emplace(x.name, m->tensors.size());
      m->tensors.push_back(std::move(x));
    }
    for(auto const &f : header.at("files").items())
    {
      m->files.emplace(f.at("name").str(),
                       std::string_view{ data + f.at("offset").integer(), static_cast<size_t>(f.at("size").integer()) });
    }
    auto const cfg{ m->files.find("config.json") };
    if(cfg == m->files.end())
    {
      fail(path + " has no config.json");
    }
    m->cfg = parse_config(cfg->second);
    m->plan = execution_plan(m->cfg);
    m->ablate.assign(m->plan.size(), 0);
    m->banned_experts.resize(static_cast<size_t>(m->cfg.layers));
    load_layers(*m);
    load_tokenizer(*m);
    prepare(*m);
    set_threads(*m, default_threads());
    m->gpu = metal_open(*m);
    return m.release();
  }

  void close(model *m)
  {
    delete m;
  }

  // Workers.

  pool::pool(int32_t const n)
  {
    for(int32_t i{}; i < n; ++i)
    {
      threads.emplace_back([this, seen = generation.load()] { worker_loop(seen); });
    }
  }

  pool::~pool()
  {
    {
      std::lock_guard const lock{ mutex };
      stopping = true;
      generation.fetch_add(1);
    }
    wake.notify_all();
    for(auto &t : threads)
    {
      t.join();
    }
  }

  void pool::work(job &j)
  {
    while(true)
    {
      auto const begin{ j.next.fetch_add(j.chunk) };
      if(begin >= j.total)
      {
        return;
      }
      auto const end{ std::min(j.total, begin + j.chunk) };
      (*j.task)(begin, end);
      j.remaining.fetch_sub(end - begin, std::memory_order_release);
    }
  }

  void pool::worker_loop(uint64_t seen)
  {
    while(true)
    {
      // Spin briefly for the next job before sleeping: a decode step starts
      // hundreds of short jobs.
      int spins{};
      while(generation.load(std::memory_order_acquire) == seen)
      {
        if(++spins < 20000)
        {
#if defined(__aarch64__)
          asm volatile("yield");
#endif
          continue;
        }
        std::unique_lock lock{ mutex };
        wake.wait(lock, [&] { return generation.load() != seen; });
      }
      seen = generation.load(std::memory_order_acquire);
      if(stopping.load())
      {
        return;
      }
      // Announce before reading `current`: run() waits for active == 0
      // after clearing it, so the job stays alive while it's read here.
      active.fetch_add(1);
      if(auto const j{ current.load() })
      {
        work(*j);
      }
      active.fetch_sub(1);
    }
  }

  void pool::run(int64_t const n, int64_t const grain, std::function<void(int64_t, int64_t)> const &fn)
  {
    if(n <= 0)
    {
      return;
    }
    if(threads.empty() || n <= grain)
    {
      fn(0, n);
      return;
    }
    job j;
    j.task = &fn;
    j.total = n;
    j.chunk = std::max<int64_t>(1, grain);
    j.remaining.store(n);
    current.store(&j, std::memory_order_release);
    {
      std::lock_guard const lock{ mutex };
      generation.fetch_add(1, std::memory_order_release);
    }
    wake.notify_all();
    work(j);
    while(j.remaining.load(std::memory_order_acquire) > 0)
    {
#if defined(__aarch64__)
      asm volatile("yield");
#endif
    }
    current.store(nullptr);
    while(active.load() > 0)
    {
    }
  }
}

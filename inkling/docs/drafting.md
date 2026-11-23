# Speculative decoding for Inkling 2 Mini, as oMLX v0.8.3 does it

This is a specification of how oMLX drafts and verifies tokens for Inkling 2
Mini, written so that the same thing can be built in this engine. Every
statement about oMLX comes with the file, function and lines that define it.
Statements about this engine are marked "In our engine" and come from reading
`native/`, `include/inkling/inkling.hpp` and the model file. Where something
is unclear, section 9 says so.

## 1. Sources

- oMLX, tag `v0.8.3`, commit `e72868dac12df4be4ced2dc8355f031686283974`
  (2026-11-22). Paths below are relative to that tree. Line numbers are those
  of that commit.
- The files that matter:
  - `omlx/patches/inkling2/dspark.py`: the draft model (config, layers,
    Markov head, loading, wrapping).
  - `omlx/speculative/dflash/drafter.py`: `DFlashDrafter`, the batched draft
    forward, its context ring, pre-drafting.
  - `omlx/speculative/dflash/selection.py`: picking the proposals
    (`select_markov`).
  - `omlx/speculative/dflash/__init__.py`: `attach_drafter`.
  - `omlx/patches/mlx_lm_mtp/batch_generator.py`: the cycle (verify,
    acceptance, rollback, emission), the depth controller.
  - `omlx/patches/mlx_lm_mtp/context_copy.py`: the context-copy drafter.
  - `omlx/patches/inkling2/model.py`: the main model, the hidden states it
    hands to the drafter, the verify rollback.
  - `omlx/patches/inkling2/cache.py`, `omlx/patches/inkling2/kernels.py`: the
    sliding-window state and the short convolutions.
  - `omlx/utils/sampling.py`: the samplers.
  - `omlx/scheduler.py`, `omlx/engine_pool.py`: prefill seeding, loading.
- PRs merged for v0.8.3: #5528 (context copies, 15 tokens), #5531 (row-exact
  verify), #5508 (pre-drafting fix), #5541 (default depth), #5538 (speed).
- The release notes of v0.8.3.
- Hugging Face, `thinkingmachines/Inkling-2-Mini`: `config.json`
  (`mtp_config`) and the header of `mtp.safetensors`. The model card says
  nothing about the draft model beyond shipping `mtp.safetensors`.

## 2. Terms

- **Lightning MTP**: oMLX's speculative decoding loop
  (`omlx/patches/mlx_lm_mtp/batch_generator.py`). It was written for embedded
  multi-token-prediction heads; a "block drafter" can replace the head as the
  source of drafts, and the verify, acceptance, rollback and emission stay the
  same.
- **DFlash**: a block drafter (block-diffusion style). A small model reads
  hidden states of a few target layers ("context") and proposes a whole block
  of tokens in one forward pass, from the newest committed token followed by
  mask positions. `DFlashDrafter` runs it.
- **DSpark**: a DFlash variant with a **Markov head**: after the one forward
  pass, a small recurrent head picks the block's tokens left to right, each
  conditioned on the token picked before it. Inkling 2 ships a DSpark drafter
  in `mtp.safetensors` (`markov_head_type: "rnn_hidden"`).
- **Anchor**: the newest committed token, sampled from the target's logits
  but not yet run through the target. The block starts with it.
- **Context row** (or tap row): for one committed position, the four hidden
  states of the main model the drafter reads (section 4.3), concatenated.
- **Cycle**: one verify forward of the target over `[anchor, d1..dk]`, the
  acceptance, the rollback, and the next draft.
- **Depth**: the number of drafts `k` verified in a cycle.
- **Committed**: a position whose token has been run through the target and
  kept in its caches.

## 3. The cycle in one page

For one sequence (oMLX drafts for Inkling 2 only when a single request is
decoding, section 8.4):

1. The prompt is prefilled. The drafter keeps the context rows of the last
   1,023 prompt positions.
2. The token after the prompt, `x_n`, is sampled as usual. oMLX runs `x_n`
   through the target alone (one-token forward, with context rows), samples
   `x_{n+1}`, and drafts a block anchored at `x_{n+1}`. Both `x_n` and
   `x_{n+1}` are emitted.
3. Every cycle after that:
   - the target runs `[anchor, d1, ..., dk]` (k at most 7, or at most 15 for
     a context copy) at positions `p .. p+k`, giving `k+1` rows of logits and
     `k+1` context rows;
   - the drafts are accepted left to right (greedy: equal to the target's
     argmax; sampled: the Leviathan/Chen rule), `m` of them;
   - the cycle emits `d1..dm` and one more token `e` from row `m` (the
     correction if `m < k`, the bonus if `m = k`);
   - the target's caches are rolled back to positions `p .. p+m` (`k-m` rows
     dropped, short-convolution histories re-cut);
   - the `m+1` committed context rows are fed to the drafter, which drafts
     the next block anchored at `e` (or a context copy replaces the block);
   - `e` is the next cycle's anchor.

Each cycle emits `m + 1` tokens for one target forward of `k + 1` rows and
one draft forward.

## 4. The draft model

### 4.1 Configuration

The draft's configuration is `mtp_config` in the checkpoint's `config.json`
(and our model file embeds the same object as `draft/config.json`, see
`native/model.cpp:240`). Values for Inkling 2 Mini, identical in our model
file and on Hugging Face:

| key | value | used for |
|---|---|---|
| `hidden_size` | 2304 | width of every draft layer (same as the target) |
| `num_hidden_layers` | 3 | draft layers |
| `num_attention_heads` | 24 | query heads |
| `num_key_value_heads` | 8 | key/value heads (3 query heads per KV head) |
| `head_dim` | 128 | |
| `intermediate_size` | 9216 | MLP width |
| `rms_norm_eps` | 1e-6 | every RMSNorm of the draft |
| `rope_theta` | 1e6 | rotary positions of the draft attention |
| `local_layer_ids` | [0, 2] | read but not used by oMLX (section 4.7) |
| `sliding_window_size` | 1024 | the drafter attends to the newest 1,023 context positions |
| `block_size` | 8 | anchor + 7 mask positions, 7 proposals |
| `markov_rank` | 256 | Markov head state width |
| `markov_head_type` | `"rnn_hidden"` | required, otherwise oMLX loads no drafter |
| `target_layer_ids` | [5, 23, 41, 48] | which target hidden states (section 4.3) |
| `q_bias`, `o_bias` | false | no biases in the draft attention |

From the target's `text_config` it also takes `vocab_size` (201024),
`unpadded_vocab_size` (200058) and `final_logit_softcapping` (30.0).

```python
# omlx/patches/inkling2/dspark.py:84-108  Inkling2DSparkConfig.from_target_config
        text = config["text_config"]
        mtp = config["mtp_config"]
        if mtp.get("q_bias") or mtp.get("o_bias"):
            raise ValueError("Inkling 2 DSpark does not support projection biases")
        return cls(
            hidden_size=int(mtp["hidden_size"]),
            ...
            sliding_window=int(mtp["sliding_window_size"]),
            block_size=int(mtp["block_size"]),
            markov_rank=int(mtp["markov_rank"]),
            target_layer_ids=[int(i) for i in mtp["target_layer_ids"]],
            vocab_size=int(text["vocab_size"]),
            unpadded_vocab_size=int(
                text.get("unpadded_vocab_size") or text["vocab_size"]
            ),
            final_logit_softcapping=float(text.get("final_logit_softcapping") or 0),
        )
```

Two fields are never read from the config and keep their defaults:
`mask_token_id = 0` and `sample_from_anchor = False`
(`dspark.py:80-81`). The second one decides the block layout (section 4.5).

oMLX loads the drafter only if the largest target layer id equals the number
of layer visits of the target (48 here), so the last id is the final-norm
output:

```python
# omlx/patches/inkling2/dspark.py:46-58  bundled_inkling2_dspark_path
    if mtp.get("markov_head_type") != "rnn_hidden":
        return None
    ...
            num_visits = len(TextArgs.from_dict(text_cfg).layer_schedule())
    ...
        if max(int(i) for i in target_ids) != num_visits:
            return None
```

### 4.2 Tensors

Our model file holds the draft tensors under `draft.`, with the names,
dtypes and shapes of `mtp.safetensors` on Hugging Face (checked: the two
lists are identical once the prefix is removed). oMLX loads that file with
`strict=True` into `Inkling2DSparkModel` (`dspark.py:341-342`), so these
names are the module paths of the classes in `dspark.py`. All are BF16.
Linear weights are `[out, in]`, applied as `y = x Wᵀ` (as `linear` in
`native/cpu.cpp:130`).

| tensor (our name) | shape | role |
|---|---|---|
| `draft.fuse_weight` | [4, 4] | row `l` (0..2) for draft layer `l`, row 3 for the Markov head; column `t` for tap `t` (section 4.4). Both dimensions are 4: rows are `num_hidden_layers + 1`, columns are `len(target_layer_ids)` (`dspark.py:292-294`) |
| `draft.mask_embed` | [2304] | input vector of every mask position |
| `draft.layers.L.dflare_norm.weight` | [2304] | RMSNorm of layer L's mix of the taps |
| `draft.layers.L.self_attn.k_proj_ctx.weight` | [1024, 2304] | context keys |
| `draft.layers.L.self_attn.v_proj_ctx.weight` | [1024, 2304] | context values |
| `draft.layers.L.self_attn.k_norm_ctx.weight` | [128] | per-head RMSNorm of context keys |
| `draft.layers.L.input_layernorm.weight` | [2304] | pre-attention RMSNorm |
| `draft.layers.L.self_attn.q_proj.weight` | [3072, 2304] | block queries (24 x 128) |
| `draft.layers.L.self_attn.k_proj.weight` | [1024, 2304] | block keys (8 x 128) |
| `draft.layers.L.self_attn.v_proj.weight` | [1024, 2304] | block values |
| `draft.layers.L.self_attn.q_norm.weight` | [128] | per-head RMSNorm of queries |
| `draft.layers.L.self_attn.k_norm.weight` | [128] | per-head RMSNorm of block keys |
| `draft.layers.L.self_attn.o_proj.weight` | [2304, 3072] | attention output |
| `draft.layers.L.post_attention_layernorm.weight` | [2304] | pre-MLP RMSNorm |
| `draft.layers.L.mlp.gate_proj.weight` | [9216, 2304] | |
| `draft.layers.L.mlp.up_proj.weight` | [9216, 2304] | |
| `draft.layers.L.mlp.down_proj.weight` | [2304, 9216] | |
| `draft.norm.weight` | [2304] | final RMSNorm of the draft |
| `draft.markov_head.dflare_norm.weight` | [2304] | RMSNorm of the Markov head's mix of the taps |
| `draft.markov_head.markov_w1.weight` | [201024, 256] | embedding of the previous token |
| `draft.markov_head.rnn_proj.weight` | [768, 5120] | the recurrent step (with bias) |
| `draft.markov_head.rnn_proj.bias` | [768] | |
| `draft.markov_head.hidden_out.weight` | [2304, 256] | latent to hidden (with bias) |
| `draft.markov_head.hidden_out.bias` | [2304] | |

`L` is 0, 1, 2. There are no other draft tensors.

The draft borrows three tensors of the main model (`dspark.py:301-306`,
`Inkling2DSparkModel.bind`): the token embedding and its norm
(`model.llm.embed.weight` [201024, 2304], `model.llm.embed_norm.weight`
[2304], the same normalized embedding the target uses, `native/cpu.cpp:952-963`)
and the output head `model.llm.unembed.weight` [201024, 2304].

```python
# omlx/patches/inkling2/dspark.py:301-314  Inkling2DSparkModel.bind
        text = target.model
        self._embed_fn = lambda tokens: text.embed_norm(text.embed(tokens))
        lm_head = target.lm_head
        self._lm_head_fn = lambda hidden: lm_head(hidden)
        alpha = mx.softmax(self.fuse_weight.astype(mx.float32), axis=-1).astype(
            mx.bfloat16
        )
        for index, layer in enumerate(self.layers):
            layer.self_attn._alpha = alpha[index]
            layer.self_attn._mix_weight = layer.dflare_norm.weight
        self.markov_head._alpha = alpha[-1]
        self.markov_head.fold(lm_head)
```

`_lm_head_fn` is the bare head: no softcap, no vocabulary mask. The softcap
and the mask are applied later, after the Markov bias is added (section 4.8).

### 4.3 What it reads from the main model

Each committed position contributes one context row: four hidden states of
the target at that position, in the order of `target_layer_ids`, each
[2304] BF16, concatenated to [9216].

oMLX numbers the target's layer visits in execution order. `target_layer_ids`
`i < 48` means "the partial block sum entering visit `i`", and `48` (the
number of visits) means "the final-norm output":

```python
# omlx/patches/inkling2/model.py:897-938  Inkling2TextModel.__call__
        """``capture`` maps draft feature ids to fill: ``i`` < num visits is
        the partial block sum entering layer visit ``i``; ``num visits`` is
        the final-norm output."""
        ...
        for visit, ((idx, loop_pass), c) in enumerate(zip(self._schedule, visits)):
            layer = self.layers[idx]
            if idx == self._core_start and prelude is None:
                prelude = (h, list(blocks))
            elif idx == self._core_start:
                ...
                h, blocks = prelude[0], list(prelude[1])
            if capture is not None and visit in capture:
                capture[visit] = h
            ...
        x = self.final_input(blocks, _unit_rms(h.astype(mx.float32)))[:, :, 0]
        _keep_fp32_weight(self.norm)
        out = _norm(self.norm, x).astype(h.dtype)
        if capture is not None and self.num_visits in capture:
            capture[self.num_visits] = out
```

The visit order is the same in oMLX (`TextArgs.layer_schedule`,
`model.py:107-128`) and in our engine (`execution_plan`,
`native/model.cpp:558`): layers 0..17 (pass 0), layers 6..17 (pass 1),
layers 6..17 (pass 2), layers 18..23. So:

| tap `t` | `target_layer_ids[t]` | what it is | in our engine |
|---|---|---|---|
| 0 | 5 | partial block sum entering layer 5, pass 0 | `w.partial` at the top of visit 5 |
| 1 | 23 | partial block sum entering layer 11, pass 1 | `w.partial` at the top of visit 23 |
| 2 | 41 | partial block sum entering layer 17, pass 2 | `w.partial` at the top of visit 41 |
| 3 | 48 | final-norm output (the input of the output head) | `w.hidden` (the mix by `output_query`, normed by `model.llm.norm.weight`, rounded) |

In our engine, "the top of visit `v`" is the start of the loop body in
`forward` (`native/cpu.cpp:986`) after the loop restart
(`cpu.cpp:991-1006`, which resets `w.partial` to the prelude's partial at
the start of passes 1 and 2). `w.partial` there is BF16-rounded
(`cpu.cpp:1124`), like oMLX's `h`, which is BF16. Layers 5, 11 and 17 are
global-attention layers; all three taps are the inputs of global layers.

In our engine, the output mix and norm are computed for the last token of a
chunk, or for every token when `session::all_logits` is on (the `output`
lambda, `cpu.cpp:1137-1175`, which was added while this spec was written);
either way the normed hidden state goes straight into the logits and is not
kept, and the three partial-sum taps are not exported. The drafter needs all
four taps for every committed position: for the last 1,023 positions of the
prompt and for every verify row.

Which positions: every position that is committed, i.e. every token that the
target has run and kept. The rows of rejected drafts are never used
(sections 4.11 and 8.1).

### 4.4 From a context row to context keys and values

Each draft layer `l` mixes the four taps with its own softmax weights,
normalizes the mix, and projects it to keys and values:

```python
# omlx/patches/inkling2/dspark.py:111-120  mix_rmsnorm
def mix_rmsnorm(context: mx.array, alpha: mx.array, weight: mx.array, eps: float):
    """Softmax-weighted sum of the context taps, RMS-normalized.

    ``context`` is ``[B, n, T * H]`` (taps concatenated in feature order).
    """
    b, n, width = context.shape
    taps = alpha.shape[0]
    x = context.reshape(b, n, taps, width // taps).astype(mx.float32)
    mixed = mx.sum(x * alpha.astype(mx.float32)[:, None], axis=2)
    return mx.fast.rms_norm(mixed, weight.astype(mx.float32), eps).astype(context.dtype)
```

```python
# omlx/patches/inkling2/dspark.py:148-150  DraftAttention.project_context_kv
    def project_context_kv(self, context: mx.array):
        mixed = mix_rmsnorm(context, self._alpha, self._mix_weight, self._eps)
        return self.k_proj_ctx(mixed), self.v_proj_ctx(mixed)
```

```python
# omlx/speculative/dflash/drafter.py:771-781  DFlashDrafter._draft_batched
            # Inkling 2 normalizes context keys with their own weights.
            ctx_k_norm = getattr(attn, "k_norm_ctx", attn.k_norm)
            ctx_keys = ctx_k_norm(
                ctx_keys.reshape(batch, width, attn.n_kv_heads, attn.head_dim)
            ).transpose(0, 2, 1, 3)
            ctx_values = ctx_values.reshape(
                batch, width, attn.n_kv_heads, attn.head_dim
            ).transpose(0, 2, 1, 3)
            ...
            ctx_keys = model.rope(ctx_keys, offset=base_arr)
```

So, for a context row at drafter position `P` (section 4.7) and layer `l`:

```
alpha_l[t]  = bf16( softmax_t( fuse_weight[l, t] ) )        computed in f32, rounded to bf16
mixed       = bf16( rmsnorm( sum_t alpha_l[t] * tap[t] ,  dflare_norm_l , 1e-6 ) )   sum and norm in f32
kc          = k_proj_ctx_l(mixed)  -> [8, 128]
kc[h]       = rmsnorm(kc[h], k_norm_ctx_l, 1e-6)            per head, over the 128 values
kc          = rope(kc, position P)
vc          = v_proj_ctx_l(mixed)  -> [8, 128]              no norm, no rope
```

This is done once per row, when the row is fed, and the result is kept in
the layer's ring (section 4.11). There is no separate "fuse" projection: the
fuse step is this softmax mix, one per layer plus one for the Markov head.

### 4.5 The block

With `sample_from_anchor = False`, the block is the anchor followed by
`block_size - 1 = 7` mask positions. The anchor row is the anchor token's
normalized embedding (the target's `embed` then `embed_norm`); the 7 mask
rows are `draft.mask_embed` as stored (not normalized). The token id used
for the masks (0) is overwritten and does not matter.

```python
# omlx/speculative/dflash/drafter.py:677-700  DFlashDrafter._draft_batched
        # DSpark's anchor row proposes the first token, so its block holds the
        # anchor plus block - 2 masks and keeps every row.
        markov = getattr(model, "markov_head", None)
        anchor_slot = markov is not None and bool(
            getattr(model.config, "sample_from_anchor", False)
        )
        if anchor_slot:
            block -= 1
        masks = mx.full(
            (batch, block - 1), int(model.config.mask_token_id), dtype=mx.int32
        )
        inputs = mx.concatenate([anchors[:, None], masks], axis=1)
        h = model._embed_input_tokens(inputs)
        ...
        if self.mask_embedding is not None:
            fill = self.mask_embedding.astype(h.dtype)
            h = mx.concatenate(
                [h[:, :1], mx.broadcast_to(fill, (batch, block - 1, h.shape[-1]))],
                axis=1,
            )
```

`mask_embedding` is `model.mask_embed` (`dspark.py:366-372`,
`wrap_inkling2_dspark`). The anchor row is not a proposal: only the 7 mask
rows propose (`draft_hidden = model.norm(h)[:, 1:]`, section 4.8). Mask row
`i` (1..7) proposes the token at position `anchor position + i`.

The three layers run once over all 8 rows together; the 7 tokens are then
picked one by one by the Markov head (section 4.9).

### 4.6 One draft layer

A plain pre-norm transformer layer whose attention reads the context ring
plus the block. The code is the generic `_draft_batched`; for Inkling 2 the
DFlash2 extras (`attention_conv`, `mlp_conv`, `g_proj`, value scale, sinks)
are absent, so they do nothing.

```python
# omlx/speculative/dflash/drafter.py:755-835  DFlashDrafter._draft_batched (Inkling 2 path)
        for layer_index, layer in enumerate(model.layers):
            attn = layer.self_attn
            ...
            residual = h
            x = layer.input_layernorm(h)
            ...
            queries, ctx_keys, ctx_values, prop_keys, prop_values = (
                variants.project_qkv(attn, x, h_ctx)
            )
            # (context keys and values: section 4.4, written into the ring)
            ...
            queries = attn.q_norm(
                queries.reshape(batch, block, attn.n_heads, -1)
            ).transpose(0, 2, 1, 3)
            prop_keys = attn.k_norm(
                prop_keys.reshape(batch, block, attn.n_kv_heads, -1)
            ).transpose(0, 2, 1, 3)
            prop_values = prop_values.reshape(
                batch, block, attn.n_kv_heads, -1
            ).transpose(0, 2, 1, 3)
            ...
            queries = model.rope(queries, offset=query_offsets)
            prop_keys = model.rope(prop_keys, offset=query_offsets)
            keys = mx.concatenate([ring_keys, prop_keys], axis=2)
            values = mx.concatenate([ring_values, prop_values], axis=2)
            attended = mx.fast.scaled_dot_product_attention(
                queries,
                keys,
                values,
                scale=attn.scale,
                mask=mask,
                sinks=getattr(attn, "attention_sink_bias", None),
            )
            attended = attended.transpose(0, 2, 1, 3).reshape(batch, block, -1)
            attended = attn.o_proj(variants.gate_output(attn, x, attended))
            ...
            h = residual + attended

            residual = h
            x = layer.post_attention_layernorm(h)
            ...
            x = variants.gated_mlp(layer.mlp, x)
            ...
            h = residual + x
```

```python
# omlx/speculative/dflash/variants.py:61-66  project_qkv
    context_kv = getattr(attn, "project_context_kv", None)
    if context_kv is not None:
        # Context rows have their own K/V projections (Inkling 2).
        return (attn.q_proj(x), *context_kv(context), attn.k_proj(x), attn.v_proj(x))
```

```python
# omlx/patches/inkling2/dspark.py:153-161  DraftMLP
    def __call__(self, x):
        return self.down_proj(nn.silu(self.gate_proj(x)) * self.up_proj(x))
```

Per layer `l`, for the 8 block rows `h` [8, 2304]:

```
x      = rmsnorm(h, input_layernorm_l, 1e-6)
q      = q_proj_l(x)  -> [8, 24, 128];  q[i,h] = rmsnorm(q[i,h], q_norm_l);   q = rope(q, positions T+0..T+7)
kb     = k_proj_l(x)  -> [8, 8, 128];   kb[i,h] = rmsnorm(kb[i,h], k_norm_l); kb = rope(kb, positions T+0..T+7)
vb     = v_proj_l(x)  -> [8, 8, 128]
att    = attention(q; keys = ring_l (valid slots) ++ kb; values = ring_l ++ vb), scale 1/sqrt(128),
         query head j reads KV head j / 3, no sink, no output gate
h      = h + o_proj_l(att reshaped to [8, 3072])
x      = rmsnorm(h, post_attention_layernorm_l, 1e-6)
h      = h + down_proj_l( silu(gate_proj_l(x)) * up_proj_l(x) )
```

`silu(x) = x * sigmoid(x)`. `T` is the anchor's position (section 4.7). The
draft attention has no attention bias, no convolution, no clip and no sink
(`DraftAttention`, `dspark.py:123-146`, has none of these).

### 4.7 Attention: keys, mask, positions

**Keys.** Each layer keeps a ring of context keys and values with
`capacity = 1023 + 8 = 1031` slots and one position per slot (-1 when
empty). Context row at position `P` goes to slot `P % 1031`.

```python
# omlx/speculative/dflash/drafter.py:154-163, 200-209
    def window(self) -> int:
        ...
        return int(getattr(config, "sliding_window", None) or 2048)

    def ring_slots(self) -> int:
        # mlx-vlm keeps window - 1 context tokens in front of the block.
        return self.window - 1

    def capacity(self) -> int:
        # A block of spare slots lets a predraft write every verify row
        # without overwriting a position that is still attended.
        return self.ring_slots + self.block_size
```

**Positions.** `fed` counts every context row the drafter has been given
for this request, including rows it dropped. The new rows of a draft call
get positions `base .. base+n-1` with `base = fed + skip` (skip: rows dropped
because more than 1,023 arrived at once); then `totals = base + n` is the
anchor's position, and block row `i` has position `totals + i`.

```python
# omlx/speculative/dflash/drafter.py:619-636, 705-726  DFlashDrafter._draft_batched
        for _state, row, context, _anchor, _sampler in rows:
            ...
            skip = max(0, held + int(context.shape[1]) - slots)
            ...
            bases.append(row.fed + skip)
        ...
        base_arr = mx.array(bases, dtype=mx.int32)
        if counts is None:
            totals = mx.array([b + n for b, n in zip(bases, lengths)], dtype=mx.int32)
        else:
            totals = base_arr + mx.concatenate(counts).astype(mx.int32)
        query_offsets = totals
        write_slots = [
            mx.array([(b + j) % capacity for j in range(n)], dtype=mx.int32)
            for b, n in zip(bases, lengths)
        ]
        ...
            pos[index, slots_b] = mx.arange(b, b + n, dtype=mx.int32)
        # Attend the newest ``slots`` committed positions; block keys always.
        # Unwritten slots hold position -1 until the ring fills.
        ring_valid = (
            (pos >= 0) & (pos >= (totals - slots)[:, None]) & (pos < totals[:, None])
        )
```

oMLX's `fed` starts at 0 at the first context row the drafter receives for
the request, which is not always the first token of the prompt (section
4.12). Because the attention only sees rotary angles through their
differences, the origin does not change the result in exact arithmetic.

**Mask.** For Inkling 2 the block attends both ways (the draft attention has
no `causal` attribute, `drafter.py:126-129`) and `query_windows` is False
(`drafter.py:147-149`), so every block query sees the same keys: the ring
slots whose position is in `[totals - 1023, totals)`, and all 8 block rows.

```python
# omlx/speculative/dflash/drafter.py:749-752
        else:
            mask = mx.concatenate(
                [ring_valid, mx.ones((batch, block), dtype=mx.bool_)], axis=1
            )[:, None, None, :]
```

The same window applies to all three layers, although `local_layer_ids` is
[0, 2] and so marks layer 1 as a full-attention layer. oMLX says this is on
purpose:

```python
# omlx/patches/inkling2/dspark.py:11-12  (module docstring)
Every layer, including the full-attention one, sees only the newest
``sliding_window_size - 1`` context positions.
```

So each block query reads at most 1,023 context positions before the anchor
plus the 8 block positions: a 1,024-token window ending at the anchor, plus
the masks.

**Rotary positions.** `nn.RoPE(head_dim=128, traditional=False,
base=1e6)` (`dspark.py:296`), applied to queries and block keys at
`totals + i` and to context keys at their own position, after their per-head
norms. MLX's non-traditional RoPE rotates the two halves of a head: for
`j` in 0..63, with `θ_j = P * 1e6^(-2j/128)`,

```
out[j]      = x[j] cos θ_j - x[j+64] sin θ_j
out[j+64]   = x[j] sin θ_j + x[j+64] cos θ_j
```

Values are not rotated.

### 4.8 Output: the norm, the base logits and the Markov head

```python
# omlx/speculative/dflash/drafter.py:847-866  DFlashDrafter._draft_batched
        draft_hidden = model.norm(h) if anchor_slot else model.norm(h)[:, 1:]
        ...
        logits = model._logits(draft_hidden)
        ...
        if markov is not None:
            prepare = getattr(markov, "prepare_block", None)
            if prepare is not None:
                # Recurrent Markov heads start each block from the newest
                # committed context row. A predraft's context holds every
                # verify row, and only ``counts`` of them commit: the head
                # must not read the row of a draft the target rejected.
                newest, held = h_ctx, lengths
                if counts is not None:
                    last = mx.concatenate(counts).astype(mx.int32) - 1
                    newest = mx.take_along_axis(h_ctx, last[:, None, None], axis=1)
                    held = [1] * batch
                prepare(draft_hidden, newest, held, uids)
            proposals = selection.select_markov(markov, logits, anchors, samplers)
```

So `dh = rmsnorm(h[1..7], draft.norm.weight)` [7, 2304] and the base logits
are `unembed · dh` [7, 201024], with no softcap yet.

**The Markov head.** At the start of each block it takes the newest
committed context row (the row of the anchor's predecessor), mixes its taps
with `alpha[3]` (row 3 of the fuse weights) and normalizes with
`markov_head.dflare_norm`. Its 256-wide state starts at zero every block.

```python
# omlx/patches/inkling2/dspark.py:234-247  Inkling2MarkovHead.prepare_block
    def prepare_block(self, draft_hidden, context, lengths, uids) -> None:
        """Reset the RNN for a new block; refresh each row's committed taps."""
        rows = []
        for index, (uid, n) in enumerate(zip(uids, lengths)):
            if n:
                last = context[index : index + 1, n - 1 : n]
                self._f_rnn[uid] = mix_rmsnorm(
                    last, self._alpha, self.dflare_norm.weight, self._eps
                )[0]
            rows.append(self._f_rnn[uid])
        self._rows_f = mx.concatenate(rows, axis=0)
        self._hidden = draft_hidden
        self._state = mx.zeros((len(uids), self.rank), dtype=draft_hidden.dtype)
        self._step = 0
```

Each step adds a bias to one position's base logits, then softcaps and masks
the padded vocabulary:

```python
# omlx/patches/inkling2/dspark.py:253-279  Inkling2MarkovHead.apply_step_logits
    def apply_step_logits(self, base_logits: mx.array, prev_tokens: mx.array):
        state = self._state
        dtype = state.dtype
        inputs = mx.concatenate(
            [
                state,
                self.markov_w1(prev_tokens.reshape(-1)).astype(dtype),
                self._hidden[:, self._step].astype(dtype),
                self._rows_f.astype(dtype),
            ],
            axis=-1,
        )
        proj = self.rnn_proj(inputs).astype(mx.float32)
        r = self.rank
        gate = mx.sigmoid(proj[:, :r]).astype(dtype)
        kept = (gate * state).astype(dtype)
        blend = ((1.0 - gate) * mx.tanh(proj[:, r : 2 * r]).astype(dtype)).astype(dtype)
        self._state = kept + blend
        latent = mx.tanh(proj[:, 2 * r :]).astype(dtype)
        bias = latent @ self._fold_weight.T + self._fold_bias
        self._step += 1
        logits = base_logits.astype(mx.float32) + bias.astype(mx.float32)
        if self._softcap:
            logits = mx.tanh(logits / self._softcap) * self._softcap
        if self._vocab_bias is not None:
            logits = logits + self._vocab_bias
        return logits
```

`_fold_weight` and `_fold_bias` fold the output head into `hidden_out` once,
at load, so that a step reads a [201024, 256] matrix instead of the head:

```python
# omlx/patches/inkling2/dspark.py:209-232  Inkling2MarkovHead.fold
        proj = self.hidden_out.weight.astype(mx.float32)
        bias = self.hidden_out.bias.astype(mx.float32)
        rows, biases = [], []
        for start in range(0, weight.shape[0], 16384):
            head = weight[start : start + 16384].astype(mx.float32)
            rows.append((head @ proj).astype(mx.bfloat16))
            biases.append((head @ bias).astype(mx.bfloat16))
            ...
        self._fold_weight = mx.concatenate(rows, axis=0)
        self._fold_bias = mx.concatenate(biases, axis=0)
```

(`weight` is the output head, dequantized first if it is quantized.)

Written out, with `dtype` BF16 (the draft's activations are BF16):

```
fold_W[v, :] = bf16( unembed[v, :] · hidden_out.weight )      [201024, 256], products in f32
fold_b[v]    = bf16( unembed[v, :] · hidden_out.bias )         [201024]

f   = bf16( rmsnorm( sum_t alpha_3[t] * newest_row.tap[t], markov_head.dflare_norm, 1e-6 ) )
s   = 0  (256 values)
prev = anchor
for i in 0 .. count-1:
    u     = f32( rnn_proj( [ s , markov_w1[prev] , dh[i] , f ] ) )      input order: 256 + 256 + 2304 + 2304 = 5120
    g     = bf16(sigmoid(u[0:256]))
    s     = bf16(g * s) + bf16( (1 - g) * bf16(tanh(u[256:512])) )
    z     = bf16(tanh(u[512:768]))
    bias  = z · fold_Wᵀ + fold_b                                       [201024]
    L_i   = 30 * tanh( (base_logits[i] + bias) / 30 )                   in f32
    L_i[v] = -inf for v >= 200058
    d_i   = choose(L_i)          (section 4.9)
    prev  = d_i
```

In exact arithmetic, `bias = unembed · hidden_out(z)`, so
`L_i = softcap30( unembed · (dh[i] + hidden_out.weight · z + hidden_out.bias) )`:
the Markov head moves the draft hidden state before the shared output head.
The fold is a speed choice, not part of the model.

The Markov head is not quantized in oMLX (section 4.13).

### 4.9 Choosing the proposals

```python
# omlx/speculative/dflash/selection.py:40-71  select_markov
    batch = len(samplers)
    prev = anchors.reshape(-1)
    tokens, accepts = [], [[] for _ in range(batch)]
    for step in range(logits.shape[1]):
        step_logits = markov.apply_step_logits(logits[:, step], prev)
        if all(sampler is None for sampler in samplers):
            prev = mx.argmax(step_logits, axis=-1)
        else:
            lp = step_logits - mx.logsumexp(step_logits, axis=-1, keepdims=True)
            picks = []
            for index, sampler in enumerate(samplers):
                if sampler is None:
                    picks.append(mx.argmax(step_logits[index : index + 1], axis=-1))
                    continue
                token, accept_lp = bg._sample_draft_with_logprobs(
                    sampler, lp[index : index + 1]
                )
                picks.append(token.reshape(1))
                accepts[index].append(accept_lp.reshape(-1))
            prev = mx.concatenate(picks)
        tokens.append(prev)
    return [
        ([token[index : index + 1] for token in tokens], accepts[index])
        for index in range(batch)
    ]
```

- **Greedy request** (temperature 0): `d_i = argmax(L_i)` (MLX's argmax
  returns the lowest index on ties). No draft distribution is kept.
- **Sampled request**: the draft sampler is built with the request's own
  temperature, top-p, top-k and min-p (`_resolve_draft_sampler`,
  `batch_generator.py:3106-3131`). It applies those filters to
  `lp_i = L_i - logsumexp(L_i)`, divides by the temperature, samples `d_i`
  from that, and keeps its normalized log density `q_i` (the "accept lp")
  for the acceptance (section 6.2):

```python
# omlx/utils/sampling.py:259-278  make_sampler (inner functions)
        def sampling_logits(logprobs: mx.array):
            for method in sampling_methods:
                logprobs = method(logprobs)
            return logprobs * (1 / temp)

        def sample_with_logprobs(logprobs: mx.array, *, rowwise: bool = False):
            # Draft sampling and its acceptance density share the same filters.
            scaled = sampling_logits(logprobs)
            ...
                token = mx.random.categorical(scaled)
            density = scaled.astype(mx.float32)
            density = density - mx.logsumexp(density, axis=-1, keepdims=True)
            return token, density
```

The filters are those of `make_sampler` (section 6.2). `q_i` is
conditioned on the drafts picked before it, as the acceptance rule needs.

The Markov steps are sequential; the base logits of all 7 positions come
from one matmul. oMLX keeps each step lazy and evaluates only the steps the
cycle will verify:

```python
# omlx/speculative/dflash/drafter.py:169-191  _proposal_count, _commit_proposals
    def _proposal_count(self, state) -> int:
        """Drafts the row's depth controller asks to verify next."""
        count = min(self.depth, int(getattr(state, "depth", 0) or self.depth))
        controller = getattr(state, "controller", None)
        if controller is not None:
            count = max(0, min(count, int(controller.cur)))
        return count

    def _commit_proposals(self, state, tokens, accept_lps) -> None:
        """Hand the row its drafts and their draft distributions."""
        if isinstance(tokens, list):
            # DSpark keeps one lazy token per position; only the prefix the
            # row's depth controller verifies next is evaluated.
            count = self._proposal_count(state)
            tokens = (
                mx.concatenate(tokens[:count])
                if count
                else mx.zeros((0,), dtype=mx.uint32)
            )
            accept_lps = accept_lps[:count]
        ...
```

An engine needs to run only `count` Markov steps (and, if it wishes, only
`count` rows of base logits).

### 4.10 Block size and depth

- Block: 8 rows (anchor + 7 masks), from `block_size`
  (`wrap_inkling2_dspark` passes `block_size=model.config.block_size`,
  `dspark.py:366-372`).
- Maximum model drafts per cycle: `depth = block_size - 1 = 7`:

```python
# omlx/speculative/dflash/drafter.py:120-122  DFlashDrafter.__init__
        self.block_size = int(block_size)
        # Lightning MTP reads this as the maximum draft depth.
        self.depth = self.block_size - 1
```

```python
# omlx/patches/inkling2/dspark.py:373-375  wrap_inkling2_dspark
    if depth:
        drafter.depth = max(1, min(drafter.depth, int(depth)))
    drafter.context_copy = True
```

  A user setting (`mtp_fixed_depth` or `mtp_adaptive_max_depth`,
  `engine_pool.py:4599-4627`) can only lower it. `attach_drafter` copies it
  to the model (`_omlx_mtp_depth = drafter.depth`,
  `speculative/dflash/__init__.py:242-252`) and the loop clamps depths to at
  most 8 (`_resolve_mtp_chain_depth`, `batch_generator.py:2406`;
  `MAX_LIGHTNING_MTP_DRAFT_TOKENS = 8`, `model_settings.py:39`).
- **About "8 for Inkling 2".** The v0.8.3 release notes say a saved depth of 3
  no longer overrides "DeepSeek V4.1's 5 and Gemma 4's and Inkling 2's 8"
  (#5541). The PR itself says "Inkling 8", and the code it refers to is the
  `inkling` / `inkling_mm_model` model types (Inkling Small, whose checkpoint
  has 8 embedded MTP blocks):

```python
# omlx/utils/model_loading.py:1038-1044
            elif model_type in ("inkling", "inkling_mm_model"):
                # The checkpoint ships one MTP block per draft depth; cap
                # the chain at the shipped depth (8 on Inkling Small).
                mtp_cfg = config.get("mtp_config") or {}
                set_mtp_depth(
                    int(mtp_cfg.get("num_nextn_predict_layers", 0) or 0) or 3
                )
```

  Inkling 2 (`inkling2_loop`) falls to `set_mtp_depth(3)` there
  (`model_loading.py:1054`), which only concerns embedded heads; its block
  drafter sets the depth itself, to 7. PR #5528 confirms it: "a reply that
  repeats the context ... was drafted at most 7 tokens at a time". So for
  Inkling 2 Mini with its DSpark drafter: at most 7 model drafts per cycle
  (8 verify rows), and at most 15 copied drafts (16 verify rows, section 7).
  The adaptive controller (section 8.2) picks the depth between 0 and 7 every
  cycle, starting at 7.

### 4.11 State kept between cycles

Per request, the drafter keeps (`_RowContext`, `drafter.py:26-53`):

- **The context ring of each draft layer**: keys (with RoPE applied) and
  values of context rows, `[8 heads, 1031 slots, 128]` BF16 each, and one
  position per slot (`int32`, -1 when empty). About 12.7 MB for the three
  layers. Rows are written once and read by every later block while they are
  among the newest 1,023 positions.
- **`fed`**: the number of context rows given so far (the next row's
  position).
- **Pending rows**: raw context rows (the four taps, [9216]) given but not
  yet projected, at most the newest 1,023 (older ones are dropped and counted
  in `fed`). They are projected at the next draft. This happens for prefill
  rows, for rows of ordinary one-token steps, and for rows of cycles whose
  drafts came from a context copy without pre-drafting (section 7).

```python
# omlx/speculative/dflash/drafter.py:230-253  DFlashDrafter._bound_pending
        # Only the newest ring_slots rows are ever attended, so rows queued
        # while drafting is off are dropped here; fed still counts them.
        drop = row.pending_len - self.ring_slots
        ...
        row.fed += drop
        row.pending_len -= drop
        ...
```

- **The Markov head's `f`**: the mixed and normalized newest committed row,
  refreshed at every block (`_f_rnn`, `dspark.py:203`, `234-247`). The RNN
  state itself is reset to zero at every block and not kept.
- **History**: the newest 1,023 raw rows, kept to restore the context of a
  later request that hits the prefix cache (`_remember`,
  `drafter.py:410-419`; `_KeptContext`, up to 8 finished requests). Only
  needed with a prefix cache.

The loop keeps per request, besides the target's caches: the next anchor
(`next_main`), the drafts and their draft densities, the depth controller
(section 8.2), the context-copy index (section 7) and statistics
(section 8.5).

### 4.12 How the context is filled

1. **Prefill.** The scheduler asks the target for the four taps on the
   prompt chunks that reach the last 1,024 prompt positions. The last prompt
   token is not part of prefill: it goes through the first ordinary decode
   step.

```python
# omlx/scheduler.py:6012-6032  Scheduler._dflash_prefill_capture
        """Request drafter layer captures for the chunk's tail inside the window.

        Returns the chunk-local offset of the first position to keep, or None
        when the chunk ends before the drafter's context window starts. The
        window covers the prompt's last tokens; the last prompt token itself
        is captured by the ordinary decode step after insert.
        """
        ...
        keep_from = len(request.prompt_token_ids) - drafter.window
        ...
        model_kwargs["capture_layer_ids"] = list(drafter.target_layer_ids)
        return max(0, keep_from - start)
```

2. **First decode step** (the last prompt token): an ordinary one-token
   forward inside the drafter's scope captures the taps and queues them:

```python
# omlx/patches/inkling2/model.py:1048-1069  Model.forward
        scope = getattr(drafter, "scope_uids", None)
        # An ordinary decode step keeps the committed token in the drafter
        # context.
        observe = bool(
            capture_layer_ids is None
            and not return_hidden
            and scope
            and inputs is not None
            and inputs.ndim == 2
            and tuple(inputs.shape) == (len(scope), 1)
        )
        if observe:
            capture_layer_ids = list(drafter.target_layer_ids)
        ...
        if observe:
            drafter.observe(scope, captures)
            return logits
```

   Every ordinary one-token step does the same, so the context stays
   complete while drafting is parked (section 8.3).

3. **Start of drafting** (`_post_init_mtp`, `batch_generator.py:3469-3615`):
   `main_tok` (the token after the prompt, already sampled) is run alone with
   captures; its logits give `next_main_tok`; the drafter drafts from all
   queued rows with `next_main_tok` as the anchor; both tokens are queued for
   emission.

```python
# omlx/patches/mlx_lm_mtp/batch_generator.py:3514-3532, 3574-3587  _post_init_mtp
    if verify_result is None:
        verify_result = _call_backbone_captured(
            gen_batch.model,
            main_tok[:, None],
            gen_batch.prompt_cache,
            capture_layer_ids=_drafter_capture_ids(gen_batch.model),
        )
    ...
    next_main_tok = sampler(next_main_lp)  # (1,)
    ...
        if drafter is not None:
            # Block drafters keep their own per-request context and draft
            # the whole block; the depth controller only narrows the
            # verified part. The captured hidden of main_tok is the newest
            # context entry; next_main is the anchor.
            state.mtp_cache = []
            state.next_main = _ensure_uint32(next_main_tok)
            state.queue.append((int(main_tok.tolist()[0]), main_lp, "init"))
            state.queue.append(
                (int(next_main_tok.tolist()[0]), next_main_lp.squeeze(0), "init")
            )
            drafter.draft([(gen_batch, state, captured, state.next_main, prev_buf)])
```

   With a prompt `t_0 .. t_{n-1}`: the first draft's context is positions up
   to `n` (at most the newest 1,023 of them), the anchor `x_{n+1}` sits at
   position `n+1`, and the masks propose positions `n+2 .. n+8`.

4. **Every cycle**: the `m+1` committed rows of the verify (section 6.3).

### 4.13 Precision in oMLX

oMLX quantizes the three draft layers' linear weights to 8-bit affine
(group 64) at load; the Markov head, the norms, `mask_embed` and
`fuse_weight` stay BF16. The draft activations are BF16
(`context_dtype = mx.bfloat16`, `dspark.py:297`).

```python
# omlx/patches/inkling2/dspark.py:330-348
# Draft layer projections run as 8-bit affine: every cycle reads them all, and
# the target verifies every proposal, so only proposal quality is affected.
_DRAFT_QUANT = {"group_size": 64, "bits": 8}
...
    nn.quantize(
        model,
        **_DRAFT_QUANT,
        class_predicate=lambda p, m: isinstance(m, nn.Linear)
        and p.startswith("layers."),
    )
```

The drafter's numbers never change which tokens are emitted under greedy
decoding, nor the output distribution under sampling (section 6.4); they
only change how many drafts are accepted. An engine can run the draft in
BF16 or F32.

## 5. Verify

### 5.1 The verify forward

The target runs `inputs = [next_main, d1 .. dk]` in one forward, at the next
`k+1` positions, with the four taps captured for every row:

```python
# omlx/patches/mlx_lm_mtp/batch_generator.py:4610-4657  _run_verify_cycle_chain
    drafter = _drafter_for(gen_batch.model)
    if (
        drafter is not None
        and verify_result is None
        and not (state.copy_drafts and int(state.drafts.shape[0]) > drafter.depth)
    ):
        # A shared verify was already built from the drafts it was given. A
        # copy longer than the block is not the drafter's block to clip.
        _clip_block_drafts(
            state,
            state.controller.cur if state.controller is not None else state.depth,
        )
    # Adaptive depth: the chain may have drafted fewer than state.depth
    # tokens this cycle — the verify window follows the actual drafts.
    k = int(state.drafts.shape[0])
    ...
    inputs = mx.concatenate([state.next_main, state.drafts])  # (k+1,)
    ...
        verify_result = _call_backbone_captured(
            gen_batch.model,
            inputs[None, :],
            gen_batch.prompt_cache,
            n_confirmed=1,
            capture_layer_ids=_drafter_capture_ids(gen_batch.model),
        )
    logits, hidden, gdn_states = verify_result[:3]
    captured = verify_result[3] if len(verify_result) > 3 else None
```

Every row writes its keys, values and convolution inputs into the target's
caches as an ordinary chunk would; the rollback (section 5.5) removes the
rows that are not kept. `n_confirmed=1` has no effect on Inkling 2.

`_clip_block_drafts` keeps the first `controller.cur` drafts (and their draft
densities); a context copy longer than 7 is not clipped
(`batch_generator.py:4206-4222`).

### 5.2 The logits of each row

Row `j` (0..k) is the target's output at input `j`, i.e. the distribution of
the token at position `p + j + 1`: row 0 checks `d1`, row `j` checks
`d_{j+1}`, row `k` gives the bonus.

```python
# omlx/patches/inkling2/model.py:981-986  Model.logits_from_hidden
    def logits_from_hidden(self, h):
        # Decode and verify rows run the cast, softcap and vocab bias as one
        # kernel; longer prefill chunks stay eager, like the layers.
        compiled = h.shape[-2] <= _COMPILED_MAX_TOKENS
        tail = _logit_tail_compiled if compiled else _logit_tail
        return tail(self.lm_head(h), self._softcap, self._vocab_bias)
```

`_logit_tail` is `softcap(float32(logits), 30)` plus `-inf` past
`unpadded_vocab_size` (`model.py:156-158`): the same logits as a decode
step, for every row. The loop then takes `combined_lp = rows -
logsumexp(rows)` per row (`batch_generator.py:4675`).

In our engine, an eval with `session::all_logits` keeps every token's
logits in `session::row_logits`, at most `max_rows = 16` tokens per eval
(`inkling.hpp`, `cpu.cpp:1159-1169`, `1314-1316`): that is the verify's
`k+1` rows.

### 5.3 Row-exact verify

The aim (PR #5531): each verify row has the bits of the serial one-token
decode step of its token, so greedy output with drafting equals greedy output
without it, whatever was drafted, and a restart that changes the drafts does
not change the answer.

oMLX turns it on for a single sequence when the target says it can:

```python
# omlx/patches/mlx_lm_mtp/batch_generator.py:2295-2305  _call_backbone_impl
    exact_verify = bool(n_confirmed and _exact_verify_host(model) is not None)
    _rollback_mod.set_undo_armed(True)
    ...
    _set_verify_qmm_armed(
        not exact_verify,
        row_exact=inputs.shape[0] == 1 and _row_exact_verify(model),
    )
```

```python
# omlx/patches/inkling2/model.py:969-979  Model._omlx_mtp_row_exact_verify
    @property
    def _omlx_mtp_row_exact_verify(self) -> bool:
        """Verify rows reproduce the serial decode rows only when every
        projection they take is a QuantizedLinear (``row_exact_qmv``); a dense
        multi-row matmul has its own arithmetic."""
        linears = [self.lm_head]
        for layer in self.model.layers:
            attn = layer.attn
            names = ("in_proj",) if attn.sliding else ("q_proj", "k_proj", "v_proj")
            linears += [getattr(attn, name) for name in names] + [attn.o_proj]
        return all(type(m) is nn.QuantizedLinear for m in linears)
```

So oMLX is row-exact on its quantized (oQ) packs, and **not** on the BF16
release, whose attention projections are dense (as in our model file). In a
row-exact forward:

- every multi-row quantized projection runs the one-row kernel per row
  (`row_exact_qmv`, `omlx/patches/qwen35_verify_qmm.py:1655-1659`);
- every attention row runs the one-token decode attention over the keys up
  to its own position:

```python
# omlx/patches/inkling2/kernels.py:421-438  banded_sink_attention
    if b == 1 and left_padding is None and is_row_exact_armed():
        # Row-exact verify: each row is the decode step of its token, over the
        # keys up to its own position. ...
        s = k.shape[2]
        rows = [
            _decode_attention(
                q[:, :, r : r + 1],
                k[:, :, : s - length + 1 + r],
                v[:, :, : s - length + 1 + r],
                rel[:, r : r + 1],
                sink[:, r : r + 1],
                scale,
                window,
            ).transpose(0, 2, 1, 3)
            for r in range(length)
        ]
```

- the router and loop-controller matmuls take one row at a time
  (`_row_matmul`, `model.py:462-473`);
- the routed experts keep the per-pair gather of a decode step instead of
  sorting pairs by expert (`do_sort = inds.size >= 64 and not
  is_row_exact_armed()`, `model.py:375`);
- the compiled layer stages keep separate traces for this mode
  (`model.py:728-731`, `814-816`).

Cost measured in PR #5531 (oQ4e, M3 Ultra): 8-row verify 47.7 → 48.5 ms,
16-row verify 65.9 → 73.6 ms, decode step 25.3 ms.

**In our engine.** The same property needs every verify row computed with
the arithmetic of a one-token `eval`. The engine was being changed toward
this while this spec was written; as of the last reading of
`native/metal.mm`:

- `linear` uses the matrix-product kernel with half-float weight copies
  only when `count > 16` (`metal.mm:675`); up to 16 tokens it uses the
  per-token kernels, whose comment says "A token's sum is the same whatever
  this is" (`metal.mm:686-688`);
- attention uses matrix products only when `nt > 16` (`metal.mm:972`); up to
  16 tokens, single tokens included, it uses `att_rows` and
  `att_rows_merge`, "a token's keys in chunks that depend on its own position
  only" (`metal.mm:1027-1057`);
- `inkling rowcheck MODEL PROMPT [ROWS]` (`native/cli.cpp:112-160`) evals
  the prompt's greedy continuation one token at a time, then the same tokens
  as one `all_logits` eval, and reports whether every row has the same bits.

`rowcheck` is the test for this property, for up to 16 rows and at
contexts long enough to reach every kernel choice (local windows full,
global attention past 2,048 keys). The CPU path (`forward` in
`native/cpu.cpp`) is a separate implementation and needs the same check if
it is used for verifies. The routed experts are one stage I did not check
for batch-dependent arithmetic.

### 5.4 The 16-row window

Inkling 2 declares that it verifies up to 16 rows, the width of its compiled
forward:

```python
# omlx/patches/inkling2/model.py:685-688
# Inputs up to this many tokens per row (decode and speculative verify) run
# the layer through compiled stages; longer prefill chunks stay eager, since
# every new chunk length would otherwise retrace all layers.
_COMPILED_MAX_TOKENS = 16
```

```python
# omlx/patches/inkling2/model.py:945-947  Model
    # Verify windows up to the compiled width keep the compiled forward, and
    # mtp_partial_rollback recuts the conv tails for any rejected count.
    _omlx_mtp_max_verify_rows = _COMPILED_MAX_TOKENS
```

Model drafts give at most 8 rows; the 16-row window is used by verbatim
context copies (15 drafts + the anchor, section 7). The convolution windows
that the rollback needs are only kept for verify-sized forwards
(`1 < length <= 16`, `model.py:829-832`).

### 5.5 Rollback

After acceptance, the target's caches must hold positions up to `p + m`
(the anchor and the `m` accepted drafts). If `m = k`, nothing is rolled back
(`_clear_rollback` only drops bookkeeping, `batch_generator.py:4964-4965`);
the bonus token is not in the caches yet and becomes the next anchor.
Otherwise `k - m` rows are dropped:

```python
# omlx/patches/inkling2/model.py:1079-1100  Model.mtp_partial_rollback
    def mtp_partial_rollback(self, cache, accepted: int, num_drafts: int) -> bool:
        """Drop the rejected drafts of a ``num_drafts + 1``-token verify."""
        rejected = int(num_drafts) - int(accepted)
        if rejected <= 0:
            return True
        keep = int(accepted) + 1
        width = self.args.text.sconv_kernel_size - 1
        for kv, conv in self.model.visit_caches(cache):
            padded = getattr(conv, "_omlx_verify_xp", None)
            if padded is None:
                return False
            if kv is None:
                if not windows.trim(conv, rejected):
                    return False
            elif kv.trim(rejected) != rejected:
                return False
            base = windows.CONV if kv is None else 0
            for slot, xp in padded.items():
                # A verify window is a few rows, so the state may stay a view.
                conv[base + slot] = xp[:, keep : keep + width]
            conv._omlx_verify_xp = None
        return True
```

For each of the 48 visits:

- **Global visits** (a `KVCache`): `trim(rejected)` lowers the offset; the
  rejected keys and values are left behind and overwritten later.
- **Sliding visits**: `windows.trim` drops the newest `rejected` keys from
  the visit's growth buffer. The buffer still holds the keys the window can
  reach after the trim, because the append that preceded the verify only cut
  keys older than the window of the position before it:

```python
# omlx/patches/inkling2/cache.py:233-242  trim
def trim(state, count: int) -> bool:
    """Drop the ``count`` newest keys: the rejected drafts of the verify
    block just appended, which the buffer still holds the window for."""
    buffer = _buffer(state)
    if buffer.keys is None or not 0 <= count <= buffer.n:
        return False
    state.cache[KEYS] = state.cache[VALUES] = buffer.view = None
    buffer.n -= count
    _publish(state, buffer)
    return True
```

- **The four short convolutions of every visit** (key, value, attention
  output, feed-forward output): each conv kernel returns its padded input
  window `xp = [previous 3 inputs ; the k+1 new inputs]` in F32
  (`kernels.short_conv` and `kernels.dynamic_conv`,
  `omlx/patches/inkling2/kernels.py:661-716`, `777-823`: "the FP32 padded
  window ``[state, x]``, whose last K-1 rows are the next state"). The layer
  keeps these windows on the cache for verify-sized forwards:

```python
# omlx/patches/inkling2/model.py:828-839  Inkling2Layer.__call__
        if conv is not None:
            padded = (ks, vs, s2, s3)
            if 1 < length <= _COMPILED_MAX_TOKENS:
                # Speculative verify rollback re-cuts the states from these.
                conv._omlx_verify_xp = dict(enumerate(padded))
            keep = self._conv_k - 1
            for slot, window in enumerate(padded):
                tail = window[:, -keep:]
                ...
                conv[base + slot] = tail if compiled else tail * 1.0
```

  On rollback, the history becomes rows `keep .. keep+2` of that window,
  `keep = m + 1`: the last 3 inputs among the anchor and the `m` accepted
  drafts (window row `r` is input `r - 3`). For the global visits' dynamic
  convolutions, the per-token taps come from each token's own projection, so
  only the inputs need restoring.

Nothing else in the target holds per-position state: the attention-residual
blocks and the loop's prelude and messages are recomputed inside each
forward. The log scaling of global attention and the relative-position bias
depend only on positions.

Tested in oMLX: a 7- and a 15-draft verify rolled back to 3 accepted equals
sequential decoding (`tests/test_inkling_vlm_mtp.py:635-664`).

### 5.6 The same in our engine's terms

From `include/inkling/inkling.hpp` and `native/cpu.cpp`:

- `session::pos` and `session::tokens`: after the verify, set `pos` back to
  `pos_before + m + 1` and drop the `k - m` rejected tokens from `tokens`.
- Key/value caches: a local visit keeps a ring of
  `min(context, window + max_chunk) = 1024 + 64` slots (`cpu.cpp:1226`,
  `slot = pos % slots`); a global visit keeps `context` slots. A verify of
  up to 16 rows at positions `P .. P+15` overwrites only slots of positions
  `<= P + 15 - 1088`, older than any key a later token can reach
  (`>= P + 1 - 1023`). So the rejected rows need no undo: lowering `pos` is
  enough, and the next rows overwrite them.
- Convolution histories: `visit_cache::conv[0..3]` hold the last 3 inputs of
  the key, value, attention-output and feed-forward-output convolutions,
  F32 `[3, width]` (`visit_cache`, `inkling.hpp:287-305`). `short_conv_apply` builds
  exactly oMLX's padded window and copies its last 3 rows back
  (`cpu.cpp:432-485`):

```cpp
// native/cpu.cpp:438-440, 484
      std::vector<float> window(static_cast<size_t>((tail + tokens) * ch));
      std::copy(history, history + tail * ch, window.begin());
      std::copy(x, x + tokens * ch, window.begin() + tail * ch);
      ...
      std::copy(window.end() - tail * ch, window.end(), history);
```

  For a rollback, keep each window of a verify forward (48 visits x 4 convs,
  `(3 + k + 1)` rows of 1024 or 2304 floats, about 24 MB at 16 rows) and set
  the history to rows `m+1 .. m+3`. Equivalently, save the 3-row histories
  before the verify and the inputs of rows `0..m`.
- The GPU path keeps its own copies of these (`metal.mm`); the same applies
  there.

## 6. Acceptance

### 6.1 Greedy

The target's token at each row is the argmax of its log-probabilities; the
drafts are accepted while they match; the token emitted after them is the
target's token at the first mismatch, or at row `k` if all match:

```python
# omlx/patches/mlx_lm_mtp/batch_generator.py:4700-4728  _run_verify_cycle_chain
    elif is_greedy or follower:
        ...
        if greedy_result is None:
            targets = _greedy_targets(combined_lp)  # (k+1,)
            matches = (targets[:k] == state.drafts.astype(mx.int32)).astype(mx.int32)
            m_arr = mx.cumprod(matches).sum().reshape(1)
            host_arr = mx.concatenate([m_arr, targets, state.drafts.astype(mx.int32)])
            ...
            host = host_arr.tolist()
        ...
        m = int(host[0])
        target_ids = host[1 : k + 2]
        draft_ids = host[k + 2 :]
        ...
        emit_last_id = target_ids[m] if m < k else target_ids[k]
        emit_last_lp = combined_lp[m if m < k else k]
```

```python
# omlx/patches/mlx_lm_mtp/batch_generator.py:1783-1793
# Serial greedy decoding (mlx-lm ``GenerationBatch._step``) samples
# ``logits - logsumexp(logits)`` in the logits dtype, so its argmax runs over
# rounded log-probabilities: ... the tie goes to the lower token id. Verify rows take
# the same argmax so greedy MTP output equals MTP-off output.
def _greedy_targets(logprobs):
    """Greedy tokens of verify rows, as the serial greedy sampler picks them."""
    import mlx.core as mx

    return mx.argmax(logprobs, axis=-1).astype(mx.int32)
```

The rule: use exactly the argmax that the non-drafting decoder uses. In our
engine that is `sample()` with temperature <= 0: `std::max_element` over the
logits, the lowest id on ties (`cpu.cpp:1347-1350`).

`m = 0 .. k`; the cycle emits `d1..dm, targets[m]`.

### 6.2 Sampled

**The target distribution `p_j`** of row `j` is the distribution the
request's sampler draws from: the filters, then the temperature, then
normalization. oMLX's sampler (`make_sampler`, `omlx/utils/sampling.py:213-301`)
works on `lp = logits - logsumexp(logits)`:

```python
# omlx/utils/sampling.py:233-255  make_sampler
        sampling_methods = []
        if 0 < top_p < 1.0 and top_k > 0 and min_p == 0.0 and xtc_probability <= 0.0:
            sampling_methods.append(lambda x: apply_top_p_top_k(x, top_p, top_k))
        else:
            if top_p > 0 and top_p < 1.0:
                sampling_methods.append(lambda x: apply_top_p(x, top_p))
            if min_p != 0.0:
                sampling_methods.append(
                    lambda x: apply_min_p(x, min_p, min_tokens_to_keep)
                )
            ...
            if top_k > 0:
                sampling_methods.append(lambda x: apply_top_k(x, top_k))

        def sampler(logprobs: mx.array) -> mx.array:
            for method in sampling_methods:
                logprobs = method(logprobs)
            return categorical_sampling(logprobs, temp)
```

Top-p keeps the tokens whose probability mass above them (at temperature 1,
over the whole vocabulary) is below `top_p`; ties at the cutoff are kept
(`apply_top_p`, `sampling.py:27-40`; `apply_top_p_top_k`, `124-144`). The
temperature divides the filtered log-probabilities afterwards.

**The draft distribution `q_j`** is the density kept when `d_j` was sampled
(section 4.9): the same filters with the same parameters, on the draft's
`L_j`, at the same temperature. For a copied draft, `q_j` is one-hot on the
copied token (section 7).

**The rule** (Leviathan et al. / Chen et al.), computed on the GPU for all
rows at once:

```python
# omlx/patches/mlx_lm_mtp/batch_generator.py:4418-4464  _stochastic_verify_tokens
    k = int(drafts.shape[0])
    top_k = _sparse_top_k(sampler)
    if top_k and k > 0:
        return _stochastic_verify_tokens_sparse(
            sampler, combined_lp, drafts, draft_accept_lps, top_k
        )
    sampling_logits = getattr(sampler, "_mtp_sampling_logits", None)
    filtered = None
    if sampling_logits is None:
        accept_rows = _accept_lp_for(sampler, combined_lp)
    else:
        filtered = sampling_logits(combined_lp)
        density = filtered.astype(mx.float32)
        accept_rows = density - mx.logsumexp(density, axis=-1, keepdims=True)
    q_rows = mx.stack(_dense_q_rows(draft_accept_lps))  # (k, V)
    idx = drafts.astype(mx.int32)[:, None]
    p_at = mx.take_along_axis(accept_rows[:k], idx, axis=-1).squeeze(-1)
    q_at = mx.take_along_axis(q_rows, idx, axis=-1).squeeze(-1)
    ratio = p_at - q_at  # (k,) log acceptance ratios
    u = mx.random.uniform(shape=(k,))
    acc = mx.logical_or(ratio >= 0, mx.log(u) < ratio)
    m_arr = mx.cumprod(acc.astype(mx.int32)).sum().reshape(1)
    # Residual distributions max(p - q, 0) per draft position. ...
    p_all = mx.exp(accept_rows[:k])
    res = mx.maximum(p_all - mx.exp(q_rows), 0.0)
    z = res.sum(axis=-1, keepdims=True)
    res_dist = mx.where(z > 0, res, p_all)
    res_samples = mx.random.categorical(mx.log(res_dist))  # (k,)
    bonus_tok = (
        sampler(combined_lp[k : k + 1])
        if filtered is None
        else mx.random.categorical(filtered[k : k + 1])
    ).reshape(1)
    return mx.concatenate(
        [
            m_arr.astype(mx.int32),
            drafts.astype(mx.int32),
            res_samples.astype(mx.int32),
            bonus_tok.astype(mx.int32),
        ]
    )
```

```python
# omlx/patches/mlx_lm_mtp/batch_generator.py:4763-4774
        m = int(host[0])
        draft_ids = host[1 : k + 1]
        res_ids = host[k + 1 : 2 * k + 1]
        bonus_id = host[2 * k + 1]
        ...
        if m < k:
            emit_last_id = res_ids[m]
            emit_last_lp = combined_lp[m]
        else:
            emit_last_id = bonus_id
            emit_last_lp = combined_lp[k]
```

In words, for `j = 1..k` in order:

1. draw `u_j` uniform in [0, 1); accept `d_j` if `p_j(d_j) >= q_j(d_j)` or
   `u_j < p_j(d_j) / q_j(d_j)`;
2. `m` = the number of leading accepted drafts (a rejection stops the run,
   later accepts do not count);
3. if `m < k`: emit a token drawn from `max(p_{m+1} - q_{m+1}, 0)`
   normalized (from `p_{m+1}` itself if that is all zero);
4. if `m = k`: emit a token drawn from `p_{k+1}` (row `k`), with the
   request's sampler (the bonus).

Here `p_j` is the target distribution that checks `d_j`, which is verify
row `j-1` in the code's 0-based numbering (`accept_rows[j-1]`), and `q_j` is
the density `d_j` was drawn from (`q_rows[j-1]`). `p_{k+1}` is row `k`.
oMLX draws all `u` and all residual samples at once and keeps the one at
`m`; that changes nothing about the distribution.

**The sparse path.** When the request's filter is exactly top-k with
`0 < top_k <= 64` (plus optional top-p, no min-p, no XTC), the same rule runs
on the top-k ids only, since `p` is zero elsewhere:

```python
# omlx/patches/mlx_lm_mtp/batch_generator.py:4245-4255, 4271-4284
def _sparse_top_k(sampler) -> int:
    """Top-k of a sampler whose target filter is exactly top-p + top-k, else 0."""
    top_k = int(getattr(sampler, "top_k", 0) or 0)
    if (
        float(getattr(sampler, "temp", 0.0) or 0.0) <= 0.0
        or not 0 < top_k <= 64
        or float(getattr(sampler, "min_p", 0.0) or 0.0) != 0.0
        or float(getattr(sampler, "xtc_probability", 0.0) or 0.0) > 0.0
    ):
        return 0
    return top_k
...
    ids = top_k_indices(combined_lp, top_k)
    vals = mx.take_along_axis(combined_lp, ids, axis=-1).astype(mx.float32)
    order = mx.argsort(-vals, axis=-1)
    vals = mx.take_along_axis(vals, order, axis=-1)
    ids = mx.take_along_axis(ids, order, axis=-1)
    if 0.0 < top_p < 1.0:
        probs = mx.exp(vals)
        vals = mx.where(mx.cumsum(probs, axis=-1) - probs < top_p, vals, -float("inf"))
    scaled = vals * (1.0 / temp)
    logp = scaled - mx.logsumexp(scaled, axis=-1, keepdims=True)  # (k+1, top_k)
    return _verify_on_support(ids, logp, drafts, draft_accept_lps)
```

`_verify_on_support` (`batch_generator.py:4287-4337`) is the same rule with
`p` given on `ids` and `q` read at those ids. A "nucleus" fast path for
top-p-only samplers exists (`_nucleus_support`, `4357-4386`), but it is
disabled whenever pre-drafting is possible (`allow_nucleus=not
(can_predraft and ...)`, `4741-4745`), which is always the case for Inkling
2 without logits processors.

**In our engine.** The rule keeps whatever distribution `p` is, as long as
`p` is exactly the distribution the engine's own sampler draws from, and the
bonus and residual draws use it. Our `sample()` (`cpu.cpp:1340-1397`) is not
oMLX's: it keeps the top-k logits, applies the temperature, and cuts top-p on
the tempered probabilities normalized over the top-k. So `p` for our engine
must be built with our `sample()`'s rule, not with oMLX's. The draft sampler
should use the same rule and parameters, as oMLX does (section 4.9);
any other `q` keeps the output exact but lowers acceptance.

### 6.3 What is emitted and committed

```python
# omlx/patches/mlx_lm_mtp/batch_generator.py:4939-4947  finish (in _run_verify_cycle_chain)
        for j in range(m):
            # Report the target row each accepted draft was verified against.
            state.queue.append((int(draft_ids[j]), combined_lp[j], "draft"))
        state.queue.append(
            (int(emit_last_id), emit_last_lp, "bonus" if m == k else "verify")
        )
```

- Emitted: `d1 .. dm`, then `e = emit_last_id`. The reported log-probability
  of each emitted token is the raw row `combined_lp[j]` (no filters).
- Kept in the target's caches: the anchor and `d1..dm` (positions `p ..
  p+m`). `e` is not in the caches; it is the next anchor.
- Fed to the drafter: the `m+1` context rows of the anchor and `d1..dm`:

```python
# omlx/patches/mlx_lm_mtp/batch_generator.py:4882-4913  draft_next
        committed_ids = [int(d) for d in draft_ids[:m]] + [int(emit_last_id)]
        committed = mx.array(committed_ids, dtype=mx.uint32)
        next_main = committed[-1:]
        ...
        if drafter is not None and predrafted and m == m_gpu:
            drafter.adopt_predraft(state, m + 1)
        elif drafter is not None:
            if predrafted:
                drafter.discard_predraft()
            rows_hidden = [c[:, : m + 1] for c in captured]
            job = (gen_batch, state, rows_hidden, committed, prev_buf)
            if copied:
                drafter.extend_context(state, rows_hidden)
            elif draft_jobs is None:
                drafter.draft([job])
```

  `drafter.draft` anchors the new block at `committed[-1] = e`
  (`drafter.py:447`).

**Stops and length.** Before committing, `m` is lowered so that nothing is
emitted past a stop sequence or the token limit; the token at the cut becomes
`e`:

```python
# omlx/patches/mlx_lm_mtp/batch_generator.py:4806-4818
    remaining = gen_batch.max_tokens[0] - gen_batch._num_tokens[0]
    limit = max(0, remaining - 1)
    ...
    matcher = copy(gen_batch._matchers[0])
    for j, token in enumerate(draft_ids[:m] + [emit_last_id]):
        if matcher.advance(token):
            limit = min(limit, j)
            break
    if limit < m:
        m = limit
        emit_last_id = draft_ids[m]
        emit_last_lp = combined_lp[m]
```

The rollback then uses the lowered `m`. (oMLX also has a model clamp and a
"commit alignment" for its paged prefix cache, `4781-4805`; neither applies
to our engine, section 8.6.)

**Depth 0.** When the controller asks for 0 drafts, the verify is a plain
one-token step of the anchor; its next token is sampled with the request's
sampler and emitted as the bonus (`4687-4699`). Nothing is rolled back.

### 6.4 Why the output distribution is unchanged

- Greedy: every emitted token is the target's argmax at a position whose
  prefix is exactly the emitted text (accepted drafts equal the argmax, and
  `e` is the argmax). If verify rows are row-exact (section 5.3), they are
  the very values a serial decode computes, so the output is identical
  token for token. Without row-exactness, rows differ by rounding and a near
  tie can flip; oMLX accepts this on its BF16 path.
- Sampled: for each position, accepting `d` with probability
  `min(1, p(d)/q(d))` and otherwise drawing from `norm(max(p - q, 0))` gives
  a token distributed exactly as `p` (Leviathan et al. 2023, Chen et al.
  2023), for any `q` that was the actual distribution `d` was drawn from,
  including a one-hot `q` for copies. Each `q_j` is conditioned on the drafts
  before it and each `p_j` on the same prefix, so the argument applies
  position by position; the bonus is a plain draw from `p_{k+1}`. Hence the
  emitted sequence has the distribution of plain sampling with the same
  sampler, provided `p` is that sampler's distribution (section 6.2). oMLX
  turns drafting off for samplers outside the rule (XTC, grammar processors,
  `_mtp_common_eligible`, `batch_generator.py:645-649`).

## 7. The context-copy drafter

Turned on for Inkling 2 by `wrap_inkling2_dspark` (`drafter.context_copy =
True`, `dspark.py:375`). It proposes the tokens that followed an earlier
occurrence of the text just written ("prompt lookup").

### 7.1 Finding a copy

```python
# omlx/patches/mlx_lm_mtp/context_copy.py:39-45
MAX_COPY = 15
_NARROW_COPY = 7
_MAX_MATCH = 64
_ENTER_MATCH = 12
_MIN_COPY = 2
_CANDIDATES = 32
_MISSES_BEFORE_QUIET = 4
_QUIET_CYCLES = 8
```

- **Index.** All tokens of the request (prompt and generated): the 3-grams
  of the tokens known when the index is (re)built, sorted (a stable sort, so
  each 3-gram's end positions are ascending), plus a dictionary of the
  3-grams of tokens appended since (`ContextCopy._rebuild`, `extend`,
  `context_copy.py:79-117`). The index is rebuilt whenever the request's
  token list is not exactly the index's (first cycle, after a fallback or a
  re-entry). A 3-gram packs three 20-bit ids (Inkling 2's vocabulary,
  201,024, fits).
- **History.** Each cycle calls `extend(history, committed)` with `history` =
  the request's tokens before this cycle's emits (prompt + everything
  emitted, ending with this cycle's anchor) and `committed` = `d1..dm, e`.
  The index then ends with the new anchor `e`.
- **Match.** Candidates are the end positions of the tail's 3-gram (the last
  three tokens), newest first: first the dictionary (generated tokens), then
  the sorted prompt index, at most 32 in all. For each candidate end `c`
  before the tail, the match length is the number of equal tokens going
  backwards from `c` and from the tail, starting at 3, at most 64. The
  longest match wins; on a tie the newest. A match shorter than 12 gives
  nothing.
- **Copy.** The tokens after the match: `ids[c+1 : c+1+take]`, with `take =
  min(limit, 7)`, or, for a verbatim run, `take = min(wide_limit, 15)`. A
  copy shorter than 2 tokens gives nothing.

```python
# omlx/patches/mlx_lm_mtp/context_copy.py:119-161  ContextCopy.propose
        if self._quiet:
            self._quiet -= 1
            return []
        ids = self._ids
        n = len(ids)
        if limit < _MIN_COPY or n <= _ENTER_MATCH:
            return []
        key = _key(ids[-3], ids[-2], ids[-1])
        # Newest first; the tail's own entry is skipped below.
        candidates = list(reversed(self._recent.get(key, ())))
        if len(candidates) < _CANDIDATES:
            lo = int(np.searchsorted(self._sorted_keys, key, "left"))
            hi = int(np.searchsorted(self._sorted_keys, key, "right"))
            lo = max(lo, hi - (_CANDIDATES - len(candidates)))
            candidates.extend(reversed(self._sorted_ends[lo:hi].tolist()))
        best_end, best_len = -1, 0
        tail = n - 1
        for end in candidates[:_CANDIDATES]:
            if end >= tail:
                continue
            length = 3
            cap = min(_MAX_MATCH, end + 1)
            while length < cap and ids[end - length] == ids[tail - length]:
                length += 1
            if length > best_len:
                best_end, best_len = end, length
                if length == _MAX_MATCH:
                    break
        if best_len < _ENTER_MATCH:
            return []
        verbatim = self._wide_window and self._wide and best_len == _MAX_MATCH
        if verbatim:
            take = min(limit if wide_limit is None else wide_limit, MAX_COPY)
        else:
            take = min(limit, _NARROW_COPY)
        copied = ids[best_end + 1 : best_end + 1 + take]
        return copied if len(copied) >= _MIN_COPY else []
```

- **Verbatim and the 15-token copy.** A copy may be 15 tokens only when all
  three hold: the target verifies 16-row windows (`wide_window`; for Inkling
  2 the declared cap 16 > 15, section 5.4), the previous copy was accepted
  whole (`_wide`), and the match is the full 64 tokens.
- **Pausing.** After a copy cycle, `observe(m, k)` sets `_wide = (m == k)`;
  a copy whose first token was rejected counts a miss, and 4 misses in a row
  pause copying for the next 8 calls:

```python
# omlx/patches/mlx_lm_mtp/context_copy.py:163-173  ContextCopy.observe
    def observe(self, accepted: int, drafted: int) -> None:
        """Allow a wide copy after one accepted whole; pause copies after
        several rounds whose first token missed."""
        self._wide = accepted == drafted
        if accepted:
            self._misses = 0
            return
        self._misses += 1
        if self._misses >= _MISSES_BEFORE_QUIET:
            self._misses = 0
            self._quiet = _QUIET_CYCLES
```

### 7.2 Combining it with the model drafter

```python
# omlx/patches/mlx_lm_mtp/batch_generator.py:4510-4540  _context_copy_drafts
    if state.context_copy is None:
        # A wide copy verifies MAX_COPY + 1 rows. A declared verify cap decides
        # (GLM-5.3's indexer pool rolls back at most 8 rows, Inkling 2 verifies
        # 16); without one only row-exact targets cover 16-row windows.
        cap = _max_verify_rows(gen_batch.model)
        state.context_copy = _context_copy.ContextCopy(
            wide_window=(
                cap > _context_copy.MAX_COPY
                if cap is not None
                else _row_exact_verify(gen_batch.model)
            )
        )
    copier = state.context_copy
    state.copy_untimed = copier.extend(gen_batch.tokens[0], committed_ids)
    # The next cycle emits up to len(drafts) + 1 tokens after the queued ones.
    room = (
        gen_batch.max_tokens[0] - gen_batch._num_tokens[0] - len(committed_ids) - 1
    )
    ...
    if copier.wide_window:
        copied = copier.propose(min(room, block), wide_limit=room)
        if len(copied) > block:
            return copied
    else:
        copied = copier.propose(min(room, block))
    return copied if len(copied) == block else []
```

It is called once per cycle, after acceptance, with `block = drafter.depth =
7` (`batch_generator.py:4893-4900`). The rules for Inkling 2:

- A copy replaces the model's block only if it has **exactly 7** tokens, or
  **8 to 15** tokens (only possible on a verbatim run). Shorter copies are
  dropped and the model drafts.
- `room` keeps a copy within the token limit.
- A 7-token copy is clipped to the controller's current depth before the
  verify like a model block; a longer copy is not (section 5.1).
- The drafter's context is still fed with the committed rows (by adopting
  the pre-draft, or by queueing them as pending, section 6.3), so the model
  drafter resumes without a gap.
- For a sampled request the copy's `q` is one-hot on each copied token, so
  acceptance is `p(token)` and the residual is `p` without that token:

```python
# omlx/patches/mlx_lm_mtp/batch_generator.py:4926-4935, 4543-4548
        if copied:
            state.drafts = mx.array(copied, dtype=mx.uint32)
            state.draft_lps = []
            # A copy is a deterministic proposer: q puts all its mass on
            # the copied token, so acceptance is p(token) and the
            # residual on rejection is p without it.
            state.draft_accept_lps = (
                [] if is_greedy else _copy_draft_q(copied, combined_lp.shape[-1])
            )
            state.copy_drafts = True
...
def _copy_draft_q(copied: List[int], vocab: int) -> SparseDraftQ:
    """One-hot draft distributions for a copied window."""
    import mlx.core as mx

    ids = mx.array(copied, dtype=mx.int32)[:, None]
    return SparseDraftQ(ids, mx.zeros(ids.shape, dtype=mx.float32), vocab)
```

- Copy cycles do not update the depth controller (`if state.controller is
  not None and not copy_cycle`, `4979`) and are counted apart in the
  statistics (`copy_cycles`, `copy_drafted`, `copy_accepted`, `4848-4852`).
  A cycle that rebuilt the copy index is not used as a time sample.
- The first cycle after the start of drafting always uses the model drafter
  (copies are proposed in `draft_next` only).

Measured in PR #5528 (rewriting a 242-line file, oQ4e, M3 Ultra): greedy
64.9 → 157.7 tok/s, sampled (temperature 1.0, top_p 0.95, top_k 20) 62.7 →
158.5 tok/s, tokens per verify cycle 3.21 → 11.58, copied drafts accepted
3270 of 3452.

## 8. Speed and other details

### 8.1 One host sync per cycle, and pre-drafting

oMLX computes the acceptance on the GPU and reads one small array per cycle
(`m`, the target ids, the drafts; or the stochastic packet). Before that
read, it queues the next draft on the GPU ("pre-drafting"), using the
GPU-side `m` and the GPU-side next anchor, so the draft overlaps the host's
bookkeeping:

```python
# omlx/patches/mlx_lm_mtp/batch_generator.py:4678-4685, 4708-4718
    can_predraft = (
        drafter is not None
        and procs is None
        and draft_jobs is None
        and commit_cache is None
        and not defer_commit
    )
    ...
            if can_predraft:
                predrafted = _predraft(
                    gen_batch,
                    state,
                    drafter,
                    captured,
                    host_arr,
                    m_arr,
                    mx.take(targets, m_arr),
                )
            host = host_arr.tolist()
```

(For sampled requests the anchor is `res[m]` if `m < k`, else the bonus,
`4746-4755`.)

```python
# omlx/speculative/dflash/drafter.py:473-511  DFlashDrafter.predraft
        row = self._row(state.uid)
        if row.restored is not None:
            return False
        unfed = row.pending_len
        context = mx.concatenate([*row.pending, _concat_captured(captured)], axis=1)
        if int(context.shape[1]) > self.ring_slots:
            return False
        ...
            proposals = self._draft_batched(
                [(state, row, context, anchor.reshape(1).astype(mx.int32), sampler)],
                counts=[count.reshape(1) + unfed],
                commit=False,
            )
```

The pre-draft writes the context keys of all `k+1` verify rows into a copy
of the ring but attends only to the committed ones (`totals = base + unfed +
m + 1`, section 4.7); its Markov head starts from the newest committed row
(the PR #5508 fix, section 4.8). If the host then commits the same `m`, the
pre-draft is adopted:

```python
# omlx/speculative/dflash/drafter.py:517-532  DFlashDrafter.adopt_predraft
        cohort.keys, cohort.values, cohort.pos = pre.keys, pre.values, pre.pos
        row = self._row(state.uid)
        row.fed = pre.bases[0] + pre.unfed[0] + int(count)
        self._take_pending(row)
        ...
        tokens, accept_lps = pre.proposals[0]
        self._commit_proposals(state, tokens, accept_lps)
```

otherwise (`m` lowered by a stop or the token limit) it is discarded and the
block is drafted from the committed rows. The rows of rejected drafts stay
in the ring labelled with positions at or after the new `fed`, so they are
masked until the same positions are written again.

With a 16-row copy verify and pre-drafting, writing 16 rows into a ring of
1,031 slots can overwrite up to `k - m - 8 = 7 - m` of the oldest positions
that are still in the window (derived from the slot arithmetic above; no
comment in oMLX mentions it). Those positions are then simply not attended.
Model blocks (k <= 7) never hit this. An implementation that writes only the
committed rows avoids it and matches the non-pre-drafted draft exactly.

Pre-drafting is off when logits processors are in use (`procs is None`).

### 8.2 Adaptive depth

`_DepthController` (`batch_generator.py:2674-3097`) picks, every cycle, how
many drafts (0..7) to verify next, from measured acceptance and measured
cycle time. It is created when drafting starts, with `max_depth = 7`, unless
the depth is fixed by a setting (`batch_generator.py:3556-3573`,
`_mtp_depth_fixed`). A new request's controller copies the previous one's
estimates (`seed`, then re-measures costs).

Constants:

```python
# omlx/patches/mlx_lm_mtp/batch_generator.py:2738-2775
    ALPHA = 0.08  # acceptance EMA weight (token domain, content-driven)
    TAU_MS = 400.0  # cost EMA horizon in wall-clock ms (load/thermal/context)
    PROBE_PERIOD_MS = 1000.0  # min wall-time between probes (light models)
    PROBE_PERIOD_MAX_MS = 5000.0  # staleness-exploration cadence floor
    PROBE_LEN = 4
    PROBE_DUTY = 0.15  # probes never consume more than ~this share of cycles
    PROBE_MARGIN = 1.15  # a rival within this score ratio is worth re-measuring
    SPIKE_RATIO = 2.0  # a cycle above this * the EMA is treated as an outlier
    SPIKE_DAMP = 0.25  # ...and folded in at this fraction of the normal weight
    MARGINAL_MS = 7.0
    HYSTERESIS = 1.03  # switch depth only for a >3% score gain
    EXIT_MARGIN = 1.15
    EXIT_STREAK = 16
    EXIT_CONFIRM = 16
```

State: `p[j]` (j = 0..6), the conditional acceptance of draft `j+1` given
the earlier ones accepted, starting `[0.6, None, ...]` (None borrows the
nearest earlier value); `t[d]`, the cycle time at depth `d`; `cur`, the next
depth, starting at 7.

After each non-copy cycle, `observe(k, m, cycle_ms)`:

1. Acceptance: for `j = 0 .. k-1`, `p[j] = 0.92 p[j] + 0.08 [j < m]`, stopping
   after the first rejected position.
2. Time: `t[k]` moves toward `cycle_ms` with weight `1 - exp(-cycle_ms /
   400)` (a quarter of that if the cycle took more than twice `t[k]`); the
   first sample of a depth replaces it; during warmup repeated samples keep
   the minimum.
3. Warmup: depths 7, 6, 5, 4, 3, 2, 1, then 0 three times, one cycle each.
4. Then every cycle `cur = argmax_d score(d)` over measured depths (0 only
   once measured), keeping `cur` unless the best is 3% better, with

```python
# omlx/patches/mlx_lm_mtp/batch_generator.py:2989-2995  _DepthController._score
    def _score(self, d: int) -> float:
        expected = 1.0
        run = 1.0
        for j in range(d):
            run *= self._p_eff(j)
            expected += run
        return expected / max(1e-6, self._t_est(d))
```

   `t_est(d)` is `t[d]` if measured, else the nearest measured depth plus the
   measured slope between the cheapest and dearest measured depths per extra
   row (7 ms before two depths are measured; for an unmeasured depth 0, the
   cheapest measured time).
5. Probes: at a period of `max(1000 ms, 4 * cycle_ms / 0.15)`, run 4 cycles
   at the best rival depth if its score is within 1.15 of the current one,
   or, every `max(5000 ms, 2 * period)`, at the depth measured longest ago.
6. Exit: if the best speculative score stays below `score(0) * EXIT_MARGIN`
   for 16 decisions including 16 speculative cycles, drafting is handed back
   to plain decoding (section 8.3). `EXIT_MARGIN` starts at 1.15 and is
   replaced by the measured ratio of a parked depth-0 cycle to a plain step
   (`_record_std_tax_sample`, `2594-2651`, clamped to [1, 1.5], decaying back
   to 1.15 over 10 minutes).

The depth the drafter hands over is `min(7, cur)` read before `observe` of
the cycle that drafted it, and the verify clips to the `cur` after it
(`_commit_proposals` runs in `draft_next`, which `finish` calls before
`controller.observe`, `batch_generator.py:4973-4992`). So a depth increase
takes effect one cycle later; a decrease applies at once.

The cycle time is the wall time of the cycle from the start of the verify to
the end of the rollback and the draft dispatch (`accept_ms` plus the
`finish` time, `4871`, `4984-4992`); the draft's GPU work runs in the
background and lands in the next cycle's time.

### 8.3 Leaving and re-entering drafting

When the controller decides drafting loses (`should_exit`), the request
leaves drafting at the end of a cycle: the anchor is run through a plain
one-token step (with its context row fed to the drafter), its successor is
sampled, and plain decoding continues (`_park_mtp_to_standard`,
`3984-4020`; `_feed_next_main_to_standard`, `3924-3981`). After 128 plain
tokens (doubling after each failed re-entry, up to 4096) drafting starts
again as in section 4.12 step 3, with a new controller
(`_MtpParkState`, `985-1019`). The drafter's per-request context is kept
across this, and plain steps keep feeding it (section 4.12 step 2). The
copy index is rebuilt.

### 8.4 One request at a time

Inkling 2 declares single-row drafting, so with two or more requests
decoding together oMLX decodes them normally, feeding each drafter context
from the ordinary steps:

```python
# omlx/patches/inkling2/model.py:1076-1077
    # Rows that accept different counts would need a ragged conv rollback.
    _omlx_drafter_single_row = True
```

```python
# omlx/speculative/dflash/__init__.py:242-252  attach_drafter
    language_model._omlx_drafter = drafter
    language_model._omlx_mtp_decode_enabled = True
    language_model._omlx_mtp_multi_request = not getattr(
        language_model, "_omlx_drafter_single_row", False
    )
    ...
    language_model._omlx_mtp_chain = True
    language_model._omlx_mtp_depth = drafter.depth
```

### 8.5 Numbers oMLX reports

Per request, at the end (`_log_mtp_stats`, `batch_generator.py:4090-4149`;
fields in `_MtpStats`, `849-881`):

```
MTP[<uid>] finish=<reason> tokens=<emitted> cycles=<C> tok/cycle=<emitted/C>
  accept=<accepted>/<drafted> (<rate>%) depth[d1=a/d,d2=a/d,...] d0=<depth-0 cycles>
  copy=<copied accepted>/<copied drafted> in <copy cycles>
  emits[init=<2>,draft=<accepted drafts>,bonus=<full accepts>,verify=<corrections>]
  timing[backbone=<ms> mtp=<ms> sample=<ms> cache=<ms>]
```

- `depth[dj=a/d]`: cycles that verified a draft at position `j`, and how
  many of those accepted it (copy cycles excluded).
- `backbone`: verify forward and its sync; `mtp`: draft dispatch (host
  time); `sample`: acceptance bookkeeping; `cache`: rollback.

Measurements in v0.8.3 (Inkling-2-Mini-oQ4e-mtp, temperature 1.0, M5 Max;
file rewrite on M3 Ultra): rewriting a 242-line file 62.7 → 158.5 tok/s
(with #5528); zero-shot coding 86.0 → 96.8 tok/s; 16K prompt decode 52.9 →
58.0 tok/s (these two from #5538, a faster forward, not from drafting
changes). From `context_copy.py:31-38`: "An 8-row window costs about 55% of
a 16-row one (M5 Ultra)". From #5531 (M3 Ultra): decode step 25.3 ms,
8-row verify 48.5 ms, 16-row verify 73.6 ms. So a verify of 8 rows costs
about 1.9 decode steps and one of 16 rows about 2.9; drafting pays off when
the tokens per cycle exceed that ratio plus the draft's own cost.

### 8.6 oMLX parts that do not apply

- Cluster ranks (`_cluster_mtp`), batched multi-request verify
  (`fused_batch.py`, `batch_policy.py`), logits processors and grammar
  (processors disable pre-drafting and are applied per row with token
  prefixes, `4630-4674`), mRoPE deltas (VLM), the paged-cache "commit
  alignment" (`_omlx_mtp_commit_align`, set by the scheduler for paged
  boundary snapshots, `scheduler.py:9642-9650`), and the embedded-head paths
  (`_chain_next_drafts`, `_dspark_next_drafts`, prompt priming): none is
  part of drafting for Inkling 2 in a single-sequence engine.
- Prefix-cache restore of drafter context (`prepare_request`,
  `drafter.py:279-308`): only needed if the engine reuses cached prefixes.
  Without it, the drafter starts with the context rows the engine computes
  after the cached prefix.

## 9. Points that are unclear or uncertain

1. **Default depth 8 versus 7.** The release notes say Inkling 2's default
   depth is 8; the code gives at most 7 model drafts (block size 8 minus the
   anchor), and PR #5541 and `model_loading.py:1038-1044` attach the 8 to
   Inkling Small. I am confident the effective maximum for Inkling 2 Mini is
   7 model drafts (8 verify rows) and 15 copied drafts (16 rows).
2. **Layer 1's window.** `local_layer_ids = [0, 2]` suggests layer 1 was
   trained with full attention over the context. oMLX limits all three
   layers to the newest 1,023 positions, and every block query to the same
   lower bound (no per-row window). I found nothing saying how the drafter
   was trained, so whether a longer context for layer 1 would accept more
   drafts is unknown.
3. **RoPE origin.** oMLX counts drafter positions from the first context row
   it received for the request, not from the first prompt token. In exact
   arithmetic this does not matter; in BF16 the angles differ slightly.
   Using the token positions of the sequence is equally valid.
4. **MLX semantics I rely on but did not read the source of:** `nn.RoPE`
   with `traditional=False` rotates the two halves of a head (MLX's
   documented behaviour); `mx.fast.rms_norm(x, w, eps) = x / sqrt(mean(x²) +
   eps) * w` with F32 accumulation; `scaled_dot_product_attention` with a
   boolean mask attends where the mask is true; `mx.argmax` returns the
   first maximum.
5. **mlx-lm's first decode step.** That prefill covers the prompt but its
   last token, which the first ordinary step then runs, comes from the
   scheduler's docstring (`scheduler.py:6012-6017`) and `_post_init_mtp`'s
   docstring ("cache contains the prompt up to prompt[-1] inclusive",
   `batch_generator.py:3472-3476`), not from mlx-lm's own code, which is
   outside the oMLX tree.
6. **Bit-level BF16 rounding of the draft.** Section 4.8 lists oMLX's casts
   in the Markov step; the draft layers' exact rounding (8-bit affine
   weights, BF16 activations) was not traced further, since it only affects
   acceptance.
7. **The 16-row pre-draft overlap** (section 8.1) is my derivation from the
   ring arithmetic; oMLX does not discuss it.
8. **Our engine was changing while this was written** (`all_logits`,
   `row_logits`, `max_rows`, `att_rows`, `rowcheck` appeared during the
   reading). The "In our engine" notes describe the files as last read; the
   oMLX parts do not depend on them. Whether every stage of a 16-row eval is
   row-exact (the routed experts in particular) is for `rowcheck` to show.

## Appendix A. A cycle as pseudo-code

For one sequence. `target.eval_rows(tokens)` runs tokens at the next
positions and returns per-row logits (softcapped, padded vocabulary masked)
and per-row taps `[t5, t23, t41, t48]`, and keeps per-visit convolution
windows. `D` is the drafter state of section 4.11.

```
# start (after the prompt, whose taps for the last 1,023 positions are in D.pending)
x_n          = sample(logits of the last prompt token)
logits, taps = target.eval_rows([x_n])                 # position n
D.pending   += taps
anchor       = sample(logits[0])                        # x_{n+1}
emit x_n, anchor
drafts, q    = D.draft(anchor, count = ctl.cur)         # section 4

loop:
    k            = len(drafts)                          # already clipped to ctl.cur unless a long copy
    logits, taps = target.eval_rows([anchor] + drafts)  # positions p .. p+k
    if greedy:
        t = [argmax(logits[j]) for j in 0..k]
        m = number of leading j with drafts[j] == t[j]
        e = t[m]
    else:
        P_j = sampler distribution of logits[j]          # the engine's own sampler rule
        m = 0
        while m < k and accept(drafts[m] with prob min(1, P_m(d)/q_m(d))): m += 1
        e = m < k ? draw(norm(max(P_m - q_m, 0)) or P_m) : draw(P_k)
    m, e = clamp for stop tokens and the token limit
    emit drafts[0..m-1], e
    if m < k: target.rollback(keep = m + 1)            # pos, tokens, conv histories (section 5.6)
    committed_rows = taps[0..m]
    copy = context_copy(history + drafts[0..m-1] + [e], block = 7)   # section 7
    if copy:
        D.pending += committed_rows                     # or project them now
        drafts, q = copy, one-hot
    else:
        D.pending += committed_rows
        drafts, q = D.draft(e, count = min(7, ctl.cur))
    if not copy cycle: ctl.observe(k, m, cycle time)
    anchor = e

D.draft(anchor, count):
    rows   = D.pending (newest 1,023); D.pending = []
    base   = D.fed + (number dropped); n = len(rows); T = base + n; D.fed = T
    for each layer l: project rows to (kc, vc) at positions base.. and write ring_l   (section 4.4)
    h      = [embed_norm(embed[anchor])] + 7 x mask_embed
    3 layers over h, keys = ring_l slots with T-1023 <= pos < T, plus the block    (sections 4.6, 4.7)
    dh     = rmsnorm(h[1..7], draft.norm)
    base_logits = unembed · dh
    f      = mix with alpha[3] of rows[n-1], rmsnorm with markov_head.dflare_norm
    Markov steps 0..count-1 (section 4.8), each picking d_i greedily or by sampling
    return d_0..d_{count-1} and, if sampled, their densities q_i
```

## Appendix B. Source index

| piece | file | lines |
|---|---|---|
| drafter config and load check | `omlx/patches/inkling2/dspark.py` | 33-108 |
| tap mix | `omlx/patches/inkling2/dspark.py` | 111-120 |
| draft attention, MLP, layer | `omlx/patches/inkling2/dspark.py` | 123-172 |
| Markov head | `omlx/patches/inkling2/dspark.py` | 175-279 |
| bind, fuse weights, fold | `omlx/patches/inkling2/dspark.py` | 301-321, 209-232 |
| 8-bit draft layers | `omlx/patches/inkling2/dspark.py` | 330-350 |
| wrap: depth 7, copies on | `omlx/patches/inkling2/dspark.py` | 353-376 |
| row state, ring sizes | `omlx/speculative/dflash/drafter.py` | 26-53, 154-209 |
| pending rows | `omlx/speculative/dflash/drafter.py` | 211-260 |
| draft, pre-draft, adopt | `omlx/speculative/dflash/drafter.py` | 425-535 |
| the draft forward | `omlx/speculative/dflash/drafter.py` | 596-898 |
| proposals | `omlx/speculative/dflash/selection.py` | 40-71 |
| taps from the target | `omlx/patches/inkling2/model.py` | 897-938, 1035-1074 |
| visit order | `omlx/patches/inkling2/model.py` | 107-128 |
| conv windows kept for rollback | `omlx/patches/inkling2/model.py` | 828-839 |
| 16-row window, row-exact flag | `omlx/patches/inkling2/model.py` | 685-688, 944-979 |
| rollback | `omlx/patches/inkling2/model.py` | 1079-1106 |
| sliding-window trim | `omlx/patches/inkling2/cache.py` | 187-242 |
| row-exact attention | `omlx/patches/inkling2/kernels.py` | 400-443 |
| conv padded windows | `omlx/patches/inkling2/kernels.py` | 642-823 |
| start of drafting | `omlx/patches/mlx_lm_mtp/batch_generator.py` | 3469-3615 |
| verify cycle | `omlx/patches/mlx_lm_mtp/batch_generator.py` | 4573-5003 |
| sampled acceptance | `omlx/patches/mlx_lm_mtp/batch_generator.py` | 4245-4464 |
| context-copy glue | `omlx/patches/mlx_lm_mtp/batch_generator.py` | 4480-4548 |
| depth controller | `omlx/patches/mlx_lm_mtp/batch_generator.py` | 2674-3097 |
| draft sampler | `omlx/patches/mlx_lm_mtp/batch_generator.py` | 3101-3131 |
| parking and re-entry | `omlx/patches/mlx_lm_mtp/batch_generator.py` | 985-1064, 3924-4020 |
| statistics | `omlx/patches/mlx_lm_mtp/batch_generator.py` | 849-881, 4090-4149 |
| context copy | `omlx/patches/mlx_lm_mtp/context_copy.py` | 1-173 |
| samplers | `omlx/utils/sampling.py` | 27-144, 213-301 |
| prefill seeding | `omlx/scheduler.py` | 6003-6060 |
| loading for Inkling 2 | `omlx/engine_pool.py` | 4599-4627 |

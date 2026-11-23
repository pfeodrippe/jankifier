module
public import Veil

/-!
# The residual stream's bookkeeping, proved

`Stream.lean`'s model of the two versions of the residual stream (`cpu.cpp`
by value, `metal.mm` in slots from a free list), side by side, with its
properties proved for every plan the engine accepts (`#check_invariants`),
instead of model checked one plan at a time. `Stream.lean` keeps the model
checks of particular plans, the plans the engine refuses and the comparison
with the engine's recorded events.

The plan is the theory: `layers`, block boundaries (`boundary l` is
`l % residual_block = 0`; kept as a relation, about which the proof uses only
that the loop starts on one), and the loop over `[loopStart, loopEnd)` run
`passes` times. `parse_config` refuses a loop that doesn't start and end on
boundaries, or runs fewer than twice.

`metal_open` refuses (leaves to the CPU) a plan in which, following the
plan's visits, the blocks plus the partial sum would be more than the
kernels' sources (6), the previous pass's sources more than 2, or the live
slots more than there are (12). The model does that count too, as ghost
state, at the same points (after a loop's restart and a boundary's push), and
stops where the engine would refuse: the properties are about the runs of the
plans the engine runs on the GPU. The counts are the engine's own
(`eBlocks`, `ePrevious`, `eLive`); invariants relate them to the model's lists
and free list.

Properties, each checked at the point it is about and kept in a ghost boolean
(they are `Stream.lean`'s properties, which there set one fault): at every read
the slot version reads the values the by-value version reads (blocks, partial
sum, previous pass: `reads_agree`) and no released slot (`no_read_after_release`),
and the lists fit the kernels' parameters (`sources_fit`, `previous_fit`); a
write of the partial sum hits no block, message source or prelude
(`no_write_to_live_slot`); the free list has a slot at every take
(`slots_enough`); a loop's restart finds a block after the prelude's
(`restart_in_range`) and the prelude's value intact (`prelude_kept`).
-/

set_option veil.smt.trust false
-- Veil's instance for the conjunction of this many invariants needs more
-- than the default search.
set_option synthInstance.maxHeartbeats 400000

veil module StreamProof

type slot
type bidx
/- The properties, each kept in `ok` as a ghost boolean. -/
enum prop_t = { p_release, p_agree, p_fit, p_write, p_slots, p_restart }
enum step_t = { s_embed_take, s_embed_write, s_visit, s_release, s_attn_read, s_push, s_take,
                s_attn_write, s_ffn_read, s_ffn_write, s_out_read, s_done }

immutable individual layers : Nat
immutable relation boundary : Nat → Bool
immutable individual hasLoop : Bool
immutable individual loopStart : Nat
immutable individual loopEnd : Nat
immutable individual passes : Nat
immutable individual nSlots : Nat
/- Positions in a list of blocks, and the position of a number. -/
immutable function bord : bidx → Nat
immutable function blockAt : Nat → bidx
/- What the Metal kernels' parameters have room for: vec_params::src and
vec_params::prev. -/
immutable individual maxSrc : Nat
immutable individual maxPrev : Nat
immutable function sidx : slot → Nat

individual step : step_t
individual layer : Nat
individual pass : Nat
individual clock : Nat

/- cpu.cpp: by value. -/
individual cPartial : Nat
function cBlock : bidx → Nat
individual cN : Nat
individual cPreludeBlocks : Nat
individual cPreludePartial : Nat
function cPrev : bidx → Nat
individual cPrevN : Nat

/- metal.mm: by slot. -/
function content : slot → Nat
individual mPartial : slot
function mBlock : bidx → slot
individual mN : Nat
individual mPreludeBlocks : Nat
individual mPreludePartial : slot
function mPrev : bidx → slot
individual mPrevN : Nat
relation free : slot → Bool
function freePos : slot → Nat
individual nFree : Nat
individual toRelease : Nat

/- metal_open's count (ghost): blocks, previous, prelude and live slots. -/
individual eBlocks : Nat
individual ePrevious : Nat
individual ePrelude : Nat
individual eLive : Nat
individual refused : Bool

/- Ghost: the prelude is still needed; the partial sum's slot was just taken
and not written yet; whether each property held at every point it is about
(a read, a write, a take, a restart). -/
individual preludeLive : Bool
individual justTook : Bool
relation ok : prop_t → Bool

#gen_state

/- The plan: a loop starts on a boundary, ends after it starts, within the
layers, and runs at least twice. -/
assumption [aligned] hasLoop → boundary loopStart
assumption [loop_shape] hasLoop → loopStart < loopEnd ∧ loopEnd ≤ layers ∧ 2 ≤ passes
/- Slots: there is at least one. Block positions: numbered, up to the
kernels' limit at least. -/
assumption [slots_exist] 0 < nSlots
assumption [bidx_ords] bord I = bord J → I = J
assumption [block_positions] ∀ n, n ≤ maxSrc + maxPrev → bord (blockAt n) = n
/- Slots are numbered 0 .. nSlots - 1; the free list starts with every slot,
the last first. The kernels take at least the partial sum. -/
assumption [kernel_limits] 1 ≤ maxSrc
assumption [slot_ords] sidx S = sidx T → S = T
assumption [slot_range] sidx S < nSlots
assumption [slots_all] ∀ i, i < nSlots → ∃ s, sidx s = i

after_init {
  step := s_embed_take
  layer := 0
  pass := 0
  clock := 1
  cPartial := 0
  cBlock I := 0
  cN := 0
  cPreludeBlocks := 0
  cPreludePartial := 0
  cPrev I := 0
  cPrevN := 0
  content S := 0
  mN := 0
  mPreludeBlocks := 0
  mPrevN := 0
  -- free_slots is filled from the last slot to slot 0, and taken from its end.
  free S := true
  freePos S := nSlots - 1 - sidx S
  nFree := nSlots
  toRelease := 0
  eBlocks := 0
  ePrevious := 0
  ePrelude := 0
  eLive := 0
  refused := false
  preludeLive := false
  justTook := false
  ok P := true
}

/- `uint32_t partial{ take() }` (metal_open counts it: live = 1). -/
action embedTake {
  require step = s_embed_take
  let s :| free s ∧ freePos s + 1 = nFree
  free s := false
  nFree := nFree - 1
  mPartial := s
  eLive := 1
  justTook := true
  step := s_embed_write
}

/- The embeddings are the first partial sum. -/
action embedWrite {
  require step = s_embed_write
  content S := if S = mPartial then clock else content S
  cPartial := clock
  clock := clock + 1
  justTook := false
  step := s_visit
}

/- A visit starts: the prelude is noted at the loop's first pass, and a later
pass restarts from it. After the last visit comes the output. -/
action visitBegin {
  require step = s_visit
  if layer = layers then
    step := s_out_read
  else
    if hasLoop ∧ layer = loopStart ∧ pass = 0 then
      cPreludeBlocks := cN
      cPreludePartial := cPartial
      mPreludeBlocks := mN
      mPreludePartial := mPartial
      ePrelude := eBlocks
      preludeLive := true
      step := s_attn_read
    else
      if hasLoop ∧ layer = loopStart then
        toRelease := 0
        step := s_release
      else
        step := s_attn_read
}

/- `for(slot : previous) free_slots.push_back(slot)`. -/
action releaseOne {
  require step = s_release ∧ toRelease < mPrevN
  let s := mPrev (blockAt toRelease)
  free S := if S = s then true else free S
  freePos S := if S = s then nFree else freePos S
  nFree := nFree + 1
  toRelease := toRelease + 1
}

/- The previous pass's blocks after the prelude's, and its partial sum,
become `previous`; the stream is the prelude again. metal_open: `if(blocks <
prelude + 1) refuse; live -= previous; previous = blocks - prelude; blocks =
prelude`. -/
action restart {
  require step = s_release ∧ toRelease = mPrevN
  ok p_restart := ok p_restart ∧ decide (cPreludeBlocks + 1 ≤ cN ∧ content mPreludePartial = cPreludePartial)
  let cpb := cPreludeBlocks
  let mpb := mPreludeBlocks
  let cn := cN
  let mn := mN
  let cp := cPartial
  let mp := mPartial
  cPrev I := if bord I + cpb + 1 < cn then cBlock (blockAt (bord I + cpb + 1)) else cp
  cPrevN := cn - cpb
  cN := cpb
  cPartial := cPreludePartial
  mPrev I := if bord I + mpb + 1 < mn then mBlock (blockAt (bord I + mpb + 1)) else mp
  mPrevN := mn - mpb
  mN := mpb
  mPartial := mPreludePartial
  eLive := eLive - ePrevious
  ePrevious := eBlocks - ePrelude
  eBlocks := ePrelude
  if pass + 1 = passes then
    preludeLive := false
  step := s_attn_read
}




/- attnRead: a visit without a boundary has its counts now; metal_open's
check (refuse, and the GPU doesn't run the plan: the model stops), then
attention reads every block and the partial sum, and with messages the
previous pass's (both versions read the same values, no released slot,
within the kernels' parameters). -/
action attnRead {
  require step = s_attn_read
  if boundary layer then
    step := s_push
  else
    if maxSrc < eBlocks + 1 ∨ maxPrev < ePrevious ∨ nSlots < eLive then
      refused := true
      step := s_done
    else
      ok p_release := ok p_release ∧ decide (¬ free mPartial ∧ (∀ i, bord i < mN → ¬ free (mBlock i)) ∧ (0 < pass → ∀ i, bord i < mPrevN → ¬ free (mPrev i)))
      ok p_agree := ok p_agree ∧ decide (mN = cN ∧ content mPartial = cPartial ∧ (∀ i, bord i < cN → content (mBlock i) = cBlock i) ∧ (0 < pass → mPrevN = cPrevN ∧ ∀ i, bord i < cPrevN → content (mPrev i) = cPrev i))
      ok p_fit := ok p_fit ∧ decide (mN + 1 ≤ maxSrc ∧ (0 < pass → mPrevN ≤ maxPrev))
      step := s_attn_write
}

/- A block boundary: attention reads, then the partial sum becomes a block
(metal_open: `++blocks; ++live`, then its check). -/
action push {
  require step = s_push
  eBlocks := eBlocks + 1
  eLive := eLive + 1
  if maxSrc < eBlocks + 1 ∨ maxPrev < ePrevious ∨ nSlots < eLive then
    refused := true
    step := s_done
  else
    ok p_release := ok p_release ∧ decide (¬ free mPartial ∧ (∀ i, bord i < mN → ¬ free (mBlock i)) ∧ (0 < pass → ∀ i, bord i < mPrevN → ¬ free (mPrev i)))
    ok p_agree := ok p_agree ∧ decide (mN = cN ∧ content mPartial = cPartial ∧ (∀ i, bord i < cN → content (mBlock i) = cBlock i) ∧ (0 < pass → mPrevN = cPrevN ∧ ∀ i, bord i < cPrevN → content (mPrev i) = cPrev i))
    ok p_fit := ok p_fit ∧ decide (mN + 1 ≤ maxSrc ∧ (0 < pass → mPrevN ≤ maxPrev))
    cBlock I := if I = blockAt cN then cPartial else cBlock I
    cN := cN + 1
    mBlock I := if I = blockAt mN then mPartial else mBlock I
    mN := mN + 1
    step := s_take
}

/- `partial = take()`. -/
action takeSlot {
  require step = s_take
  ok p_slots := ok p_slots ∧ decide (0 < nFree)
  let s :| free s ∧ freePos s + 1 = nFree
  free S := if S = s then false else free S
  nFree := nFree - 1
  mPartial := s
  justTook := true
  step := s_attn_write
}

/- Attention's output: the new partial sum after a boundary, added to it
otherwise. -/
action attnWrite {
  require step = s_attn_write
  ok p_write := ok p_write ∧ decide ((∀ i, bord i < mN → mBlock i ≠ mPartial) ∧ (∀ i, bord i < mPrevN → mPrev i ≠ mPartial) ∧ (preludeLive → mPartial ≠ mPreludePartial))
  content S := if S = mPartial then clock else content S
  cPartial := clock
  clock := clock + 1
  justTook := false
  step := s_ffn_read
}

action ffnRead {
  require step = s_ffn_read
  ok p_release := ok p_release ∧ decide (¬ free mPartial ∧ (∀ i, bord i < mN → ¬ free (mBlock i)) ∧ (0 < pass → ∀ i, bord i < mPrevN → ¬ free (mPrev i)))
  ok p_agree := ok p_agree ∧ decide (mN = cN ∧ content mPartial = cPartial ∧ (∀ i, bord i < cN → content (mBlock i) = cBlock i) ∧ (0 < pass → mPrevN = cPrevN ∧ ∀ i, bord i < cPrevN → content (mPrev i) = cPrev i))
  ok p_fit := ok p_fit ∧ decide (mN + 1 ≤ maxSrc ∧ (0 < pass → mPrevN ≤ maxPrev))
  step := s_ffn_write
}

/- The feed-forward output is added, and the next visit follows. -/
action ffnWrite {
  require step = s_ffn_write
  ok p_write := ok p_write ∧ decide ((∀ i, bord i < mN → mBlock i ≠ mPartial) ∧ (∀ i, bord i < mPrevN → mPrev i ≠ mPartial) ∧ (preludeLive → mPartial ≠ mPreludePartial))
  content S := if S = mPartial then clock else content S
  cPartial := clock
  clock := clock + 1
  justTook := false
  if hasLoop ∧ layer + 1 = loopEnd ∧ pass + 1 < passes then
    layer := loopStart
    pass := pass + 1
  else
    if hasLoop ∧ layer + 1 = loopEnd then
      layer := loopEnd
      pass := 0
    else
      layer := layer + 1
  step := s_visit
}

/- The output reads the stream. -/
action outRead {
  require step = s_out_read
  ok p_release := ok p_release ∧ decide (¬ free mPartial ∧ (∀ i, bord i < mN → ¬ free (mBlock i)) ∧ (0 < pass → ∀ i, bord i < mPrevN → ¬ free (mPrev i)))
  ok p_agree := ok p_agree ∧ decide (mN = cN ∧ content mPartial = cPartial ∧ (∀ i, bord i < cN → content (mBlock i) = cBlock i) ∧ (0 < pass → mPrevN = cPrevN ∧ ∀ i, bord i < cPrevN → content (mPrev i) = cPrev i))
  ok p_fit := ok p_fit ∧ decide (mN + 1 ≤ maxSrc ∧ (0 < pass → mPrevN ≤ maxPrev))
  step := s_done
}

/-! ## Properties -/

safety [no_read_after_release] ok p_release
safety [reads_agree] ok p_agree
safety [sources_and_previous_fit] ok p_fit
safety [no_write_to_live_slot] ok p_write
safety [slots_enough] ok p_slots
safety [restart_in_range_and_prelude_kept] ok p_restart

/-! ## Auxiliary invariants -/

invariant [refused_done] refused → step = s_done
/- Both versions' lists have the same lengths; the engine's counts are
theirs; the live slots are the partial sum, the blocks and the previous
pass's sources; the free list has the others. -/
invariant [lengths] mN = cN ∧ mPrevN = cPrevN ∧ mPreludeBlocks = cPreludeBlocks
invariant [engine_counts] ¬ refused → eBlocks = mN ∧ ePrevious = mPrevN ∧ ePrelude = mPreludeBlocks
invariant [engine_live] ¬ refused → step ≠ s_embed_take → eLive = 1 + mN + mPrevN
invariant [free_count] ¬ refused →
  nFree + eLive = nSlots + (if step = s_take then 1 else 0) + (if step = s_release then toRelease else 0)
invariant [source_bound] ¬ refused → mN + 1 ≤ maxSrc
invariant [previous_bound] ¬ refused → mPrevN ≤ maxPrev ∨ step = s_attn_read ∨ step = s_push
invariant [restart_bound] mPreludeBlocks ≤ mN ∧ mPrevN ≤ maxSrc
invariant [release_bound] step = s_release → toRelease ≤ mPrevN
/- Contents agree. -/
invariant [content_blocks] ∀ i, bord i < mN → content (mBlock i) = cBlock i
invariant [content_partial] step ≠ s_embed_take → (justTook ∨ content mPartial = cPartial)
invariant [content_prev] ∀ i, bord i < mPrevN → content (mPrev i) = cPrev i
invariant [content_prelude] preludeLive → content mPreludePartial = cPreludePartial
invariant [just_took] justTook → (step = s_embed_write ∨ step = s_attn_write)
/- Live slots aren't free; a slot is in one role at most. -/
invariant [partial_held] step ≠ s_embed_take → ¬ free mPartial
invariant [blocks_held] ∀ i, bord i < mN → ¬ free (mBlock i)
invariant [prev_held] ∀ i, bord i < mPrevN → ¬ free (mPrev i) ∨ (step = s_release ∧ bord i < toRelease)
invariant [released_free] step = s_release → ∀ i, bord i < toRelease → free (mPrev i)
invariant [blocks_distinct] ∀ i, ∀ j, bord i < mN → bord j < mN → mBlock i = mBlock j → i = j
invariant [prev_distinct] ∀ i, ∀ j, bord i < mPrevN → bord j < mPrevN → mPrev i = mPrev j → i = j
invariant [prev_not_block] ∀ i, ∀ j, bord i < mPrevN → bord j < mN → mPrev i ≠ mBlock j
invariant [prev_not_partial] step ≠ s_embed_take → ∀ i, bord i < mPrevN → mPrev i ≠ mPartial
invariant [partial_not_block] step ≠ s_embed_take → step ≠ s_take → ∀ i, bord i < mN → mBlock i ≠ mPartial
invariant [took_pushed] step = s_take → 0 < mN ∧ mBlock (blockAt (mN - 1)) = mPartial
/- Where the prelude is: the partial sum until the loop's first layer pushes
it, then the block at its position; never a previous pass's source. -/
invariant [prelude_where] preludeLive →
  (mPreludePartial = mPartial ∧ mN = mPreludeBlocks ∧ layer = loopStart
    ∧ (step = s_attn_read ∨ step = s_push ∨ step = s_done))
  ∨ (mPreludeBlocks < mN ∧ mBlock (blockAt mPreludeBlocks) = mPreludePartial)
invariant [prelude_not_prev] preludeLive → ∀ i, bord i < mPrevN → mPrev i ≠ mPreludePartial
invariant [release_prelude] step = s_release → preludeLive ∧ mPreludeBlocks < mN ∧ hasLoop ∧ layer = loopStart ∧ 0 < pass
/- The free list: free slots at distinct positions below nFree, every
position below nFree taken. -/
invariant [free_below] free S → freePos S < nFree
invariant [free_distinct] free S → free T → freePos S = freePos T → S = T
invariant [free_full] ∀ i, i < nFree → ∃ s, free s ∧ freePos s = i
/- The visits: where the loop and its prelude are. -/
invariant [layer_bound] layer ≤ layers
invariant [layer_in_visit] (step = s_release ∨ step = s_attn_read ∨ step = s_push ∨ step = s_take ∨ step = s_attn_write
  ∨ step = s_ffn_read ∨ step = s_ffn_write) → layer < layers
invariant [take_live] ¬ refused → step = s_take → eLive ≤ nSlots
invariant [pass_bound] (hasLoop → pass < passes) ∧ (¬ hasLoop → pass = 0)
invariant [pass_loop] 0 < pass → hasLoop ∧ loopStart ≤ layer ∧ layer < loopEnd
invariant [prelude_phase] preludeLive ↔
  (hasLoop ∧ ((pass = 0 ∧ loopStart ≤ layer ∧ layer < loopEnd ∧ ¬ (layer = loopStart ∧ step = s_visit)
                ∧ step ≠ s_embed_take ∧ step ≠ s_embed_write)
              ∨ (1 ≤ pass ∧ pass + 1 < passes)
              ∨ (1 ≤ pass ∧ pass + 1 = passes ∧ layer = loopStart ∧ (step = s_visit ∨ step = s_release))))
invariant [loop_entry] (step = s_visit ∧ hasLoop ∧ layer = loopStart ∧ 0 < pass) → mPreludeBlocks < mN
invariant [early_steps] (step = s_embed_take ∨ step = s_embed_write) → layer = 0 ∧ pass = 0 ∧ mN = 0 ∧ mPrevN = 0 ∧ ¬ preludeLive
invariant [first_take] step = s_embed_take → eLive = 0 ∧ nFree = nSlots ∧ ¬ refused

#gen_spec

-- For `inkling-specs.stream/proof-instance` (a run of the engine's plan).
#gen_executable

#check_invariants

end StreamProof

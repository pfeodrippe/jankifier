module
public import Veil

/-!
# The residual stream's bookkeeping

The forward pass keeps the residual stream as a list of finished blocks and
the current block's partial sum. Every sublayer reads all of them. Layers
`[loopStart, loopEnd)` run `passes` times: each pass after the first restarts
from the stream as it was before the loop (the prelude), and its inputs also
read the previous pass's blocks and partial sum (the messages' sources).

Two implementations, modelled side by side, step by step:

- `native/cpu.cpp`, `forward`: the stream by value. `blocks` and `previous`
  are vectors of vectors, `partial` and `prelude_partial` are vectors; a block
  is pushed by copying the partial sum, the prelude is kept by copying it.
- `native/metal.mm`, `metal_forward`: the stream in numbered slots of one
  buffer. `blocks` and `previous` are lists of slots, `partial` and
  `prelude_partial` are slots; pushing a block keeps its slot and takes a free
  one for the next partial sum (`free_slots`, a stack); the previous pass's
  slots are released when the next pass's are known.

A value is identified by a number: every write makes a new one (`clock`), the
same in both. `content` is the value each slot holds. The properties say that
the slot version reads what the by-value version reads, and never reads a
released slot, writes a slot that is still a block, a message source or the
prelude, or runs out of slots.

The plan's shape is the theory: `layers`, a block boundary every `block`
layers, and the loop. The visits are, as in `model.cpp`'s `execution_plan`:
layers `[0, loopEnd)`, then passes `1 ..` of `[loopStart, loopEnd)`, then
`[loopEnd, layers)`.

Each step sets the event it stands for (`evKind`, `evSlot`, `reads`), in the
order `metal_forward` records them in `session::events`.
-/

veil module Stream

type slot
type bidx
enum step_t = { s_embed_take, s_embed_write, s_visit, s_release, s_attn_read, s_push, s_take,
                s_attn_write, s_ffn_read, s_ffn_write, s_out_read, s_done }
enum ev_t = { e_none, e_take, e_push, e_restart, e_release, e_read, e_write }
/- What went wrong first, if anything. -/
enum fault_t = { ok, mismatch, prelude_lost, read_free, aliased, exhausted, src_overflow,
                 prev_overflow, bad_restart }

immutable individual layers : Nat
immutable individual block : Nat
immutable individual hasLoop : Bool
immutable individual loopStart : Nat
immutable individual loopEnd : Nat
immutable individual passes : Nat
/- The slots (`stream_slots`), their numbers, and the slot of a number. -/
immutable individual nSlots : Nat
immutable function sidx : slot → Nat
immutable function slotAt : Nat → slot
/- Positions in a list of blocks, and the position of a number. -/
immutable function bord : bidx → Nat
immutable function blockAt : Nat → bidx
/- What the Metal kernels' parameters have room for: `vec_params::src` and
`vec_params::prev`. -/
immutable individual maxSrc : Nat
immutable individual maxPrev : Nat

/- Where the forward pass is. -/
individual step : step_t
individual layer : Nat
individual pass : Nat
individual visit : Nat
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

/- Ghost: the step's event, and what went wrong. -/
individual evKind : ev_t
individual evSlot : slot
relation reads : slot → Bool
individual preludeLive : Bool
individual fault : fault_t

#gen_state

after_init {
  step := s_embed_take
  layer := 0
  pass := 0
  visit := 0
  clock := 1
  cPartial := 0
  cBlock I := 0
  cN := 0
  cPreludeBlocks := 0
  cPreludePartial := 0
  cPrev I := 0
  cPrevN := 0
  content S := 0
  mPartial := slotAt 0
  mBlock I := slotAt 0
  mN := 0
  mPreludeBlocks := 0
  mPreludePartial := slotAt 0
  mPrev I := slotAt 0
  mPrevN := 0
  -- free_slots is filled from the last slot to slot 0, and taken from its end.
  free S := true
  freePos S := nSlots - 1 - sidx S
  nFree := nSlots
  toRelease := 0
  evKind := e_none
  evSlot := slotAt 0
  reads S := false
  preludeLive := false
  fault := ok
}

/- `uint32_t partial{ take() }`. -/
action embedTake {
  require step = s_embed_take
  let s :| free s ∧ freePos s + 1 = nFree
  free s := false
  nFree := nFree - 1
  mPartial := s
  evKind := e_take
  evSlot := s
  step := s_embed_write
}

/- The embeddings are the first partial sum. -/
action embedWrite {
  require step = s_embed_write
  content S := if S = mPartial then clock else content S
  cPartial := clock
  clock := clock + 1
  evKind := e_write
  evSlot := mPartial
  step := s_visit
}

/- A visit starts: the prelude is noted at the loop's first pass, and a later
pass restarts from it. After the last visit comes the output. -/
action visitBegin {
  require step = s_visit
  evKind := e_none
  if layer = layers then
    step := s_out_read
  else
    if hasLoop ∧ layer = loopStart ∧ pass = 0 then
      cPreludeBlocks := cN
      cPreludePartial := cPartial
      mPreludeBlocks := mN
      mPreludePartial := mPartial
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
  evKind := e_release
  evSlot := s
}

/- The previous pass's blocks after the prelude's, and its partial sum,
become `previous`; the stream is the prelude again. -/
action restart {
  require step = s_release ∧ toRelease = mPrevN
  let cpb := cPreludeBlocks
  let mpb := mPreludeBlocks
  let cn := cN
  let mn := mN
  let cp := cPartial
  let mp := mPartial
  let lost := decide (content mPreludePartial ≠ cPreludePartial)
  fault := if fault ≠ ok then fault else if cn < cpb + 1 then bad_restart else if lost then prelude_lost else ok
  cPrev I := if bord I + cpb + 1 < cn then cBlock (blockAt (bord I + cpb + 1)) else cp
  cPrevN := cn - cpb
  cN := cpb
  cPartial := cPreludePartial
  mPrev I := if bord I + mpb + 1 < mn then mBlock (blockAt (bord I + mpb + 1)) else mp
  mPrevN := mn - mpb
  mN := mpb
  mPartial := mPreludePartial
  if pass + 1 = passes then
    preludeLive := false
  evKind := e_restart
  evSlot := mPreludePartial
  step := s_attn_read
}

/- A sublayer's input reads every block and the partial sum, and with
messages the previous pass's. Both versions must read the same values. -/
procedure readSources {
  reads S := decide ((∃ I, bord I < mN ∧ mBlock I = S) ∨ S = mPartial
                      ∨ (0 < pass ∧ ∃ I, bord I < mPrevN ∧ mPrev I = S))
  let differ := decide (mN ≠ cN ∨ content mPartial ≠ cPartial
                        ∨ (∃ I, bord I < cN ∧ content (mBlock I) ≠ cBlock I)
                        ∨ (0 < pass ∧ (mPrevN ≠ cPrevN ∨ ∃ I, bord I < cPrevN ∧ content (mPrev I) ≠ cPrev I)))
  let released := decide (free mPartial ∨ (∃ I, bord I < mN ∧ free (mBlock I))
                        ∨ (0 < pass ∧ ∃ I, bord I < mPrevN ∧ free (mPrev I)))
  fault := if fault ≠ ok then fault else if released then read_free else if differ then mismatch
           else if maxSrc < mN + 1 then src_overflow
           else if 0 < pass ∧ maxPrev < mPrevN then prev_overflow else ok
  evKind := e_read
}

/- Writing the partial sum: its slot must not be a block, a message source or
the prelude. -/
procedure writePartial {
  let live := decide ((∃ I, bord I < mN ∧ mBlock I = mPartial)
                       ∨ (∃ I, bord I < mPrevN ∧ mPrev I = mPartial)
                       ∨ (preludeLive ∧ mPartial = mPreludePartial))
  fault := if fault ≠ ok then fault else if live then aliased else ok
  content S := if S = mPartial then clock else content S
  cPartial := clock
  clock := clock + 1
  evKind := e_write
  evSlot := mPartial
}

action attnRead {
  require step = s_attn_read
  readSources
  if layer % block = 0 then
    step := s_push
  else
    step := s_attn_write
}

/- A block boundary: the partial sum becomes a block. -/
action push {
  require step = s_push
  cBlock I := if I = blockAt cN then cPartial else cBlock I
  cN := cN + 1
  mBlock I := if I = blockAt mN then mPartial else mBlock I
  mN := mN + 1
  evKind := e_push
  evSlot := mPartial
  step := s_take
}

/- `partial = take()`. -/
action takeSlot {
  require step = s_take
  if nFree = 0 then
    fault := if fault ≠ ok then fault else exhausted
    evKind := e_none
    step := s_done
  else
    let s :| free s ∧ freePos s + 1 = nFree
    free S := if S = s then false else free S
    nFree := nFree - 1
    mPartial := s
    evKind := e_take
    evSlot := s
    step := s_attn_write
}

/- Attention's output: the new partial sum after a boundary, added to it
otherwise. -/
action attnWrite {
  require step = s_attn_write
  writePartial
  step := s_ffn_read
}

action ffnRead {
  require step = s_ffn_read
  readSources
  step := s_ffn_write
}

/- The feed-forward output is added, and the next visit follows. -/
action ffnWrite {
  require step = s_ffn_write
  writePartial
  if hasLoop ∧ layer + 1 = loopEnd ∧ pass + 1 < passes then
    layer := loopStart
    pass := pass + 1
  else
    if hasLoop ∧ layer + 1 = loopEnd then
      layer := loopEnd
      pass := 0
    else
      layer := layer + 1
  visit := visit + 1
  step := s_visit
}

/- The output reads the stream. -/
action outRead {
  require step = s_out_read
  readSources
  step := s_done
}

/- The slot version reads the values the by-value version reads. -/
safety [reads_agree] fault ≠ mismatch
safety [prelude_kept] fault ≠ prelude_lost
/- No slot is read after its release, or written while something still reads it. -/
safety [no_read_after_release] fault ≠ read_free
safety [no_write_to_live_slot] fault ≠ aliased
/- The slots are enough, and the lists fit the kernels' parameters. -/
safety [slots_enough] fault ≠ exhausted
safety [sources_fit] fault ≠ src_overflow
safety [previous_fit] fault ≠ prev_overflow
/- A pass has a block after the prelude's (`blocks.begin() + prelude_blocks + 1`). -/
safety [restart_in_range] fault ≠ bad_restart

#gen_spec

-- For the checks driven from jank (veil/model-check, veil/system).
#gen_executable

/-! ## Model checking

The run is deterministic, so a check for a plan covers that plan. The first is
Inkling 2 Mini's: 24 layers, blocks of 6, layers 6 to 17 three times, 12 slots.
`inkling-specs.stream` checks other shapes, and compares the events with the
engine's. -/

#model_check { slot := Fin 12, bidx := Fin 6 }
  { layers := 24, block := 6, hasLoop := true, loopStart := 6, loopEnd := 18, passes := 3,
    nSlots := 12, sidx := fun s => s.val, slotAt := fun n => ⟨n % 12, Nat.mod_lt _ (by decide)⟩,
    bord := fun b => b.val, blockAt := fun n => ⟨n % 6, Nat.mod_lt _ (by decide)⟩,
    maxSrc := 6, maxPrev := 2 }

end Stream
